defmodule Frontman.Cache do
  @moduledoc false
  # Opt-in page cache for one pool. The app marks a response cacheable with the
  # `x-frontman-cache` header; Frontman decides whether it can be stored and serves it later.
  #
  # Request processes read ETS directly, so a hit never touches this server. The server owns
  # every write that changes size or content: stores, eviction, invalidation. It also
  # coordinates renders, so concurrent misses on one key send a single request to Node.
  use GenServer
  import Plug.Conn, only: [get_req_header: 2]

  @marker "x-frontman-cache"
  @status_header "x-frontman-cache-status"
  # A waiter gives up and renders for itself after this long, matching the proxy's receive
  # timeout. A refresh in flight blocks further refreshes for the same time.
  @wait 15_000
  # After a refresh fails, stale hits wait this long before starting another.
  @retry 1_000
  # Last-use times are only rewritten once per interval, so a hot page isn't a hot ETS row.
  @touch 1_000
  @defaults [max_entries: 10_000, max_bytes: 64_000_000, max_entry_bytes: 2_000_000, query: :all]
  # Headers that describe one delivery rather than the page.
  @unstored ~w(age connection content-length date keep-alive proxy-authenticate
               proxy-authorization proxy-connection set-cookie te trailer transfer-encoding upgrade
               x-request-id) ++ [@marker]
  # Headers a 304 repeats from the 200 it stands for (RFC 9110, section 15.4.5).
  @not_modified ~w(cache-control content-location etag expires vary)
  # Outcomes that say nothing about whether the page is cacheable, so a stale copy stays.
  @inconclusive [:unavailable, :aborted, :error, :method]
  @counters %{
    hit: 1,
    miss: 2,
    stale: 3,
    store: 4,
    skip: 5,
    evict: 6,
    invalidate: 7,
    bytes: 8
  }

  ## Configuration

  @doc false
  def config!(true), do: config!([])

  def config!(opts) when is_list(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "cache must be a keyword list")

    case Keyword.keys(opts) -- Keyword.keys(@defaults) do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unknown cache option #{inspect(key)}"
    end

    max_bytes = Keyword.get(opts, :max_bytes, @defaults[:max_bytes])

    defaults =
      Keyword.put(@defaults, :max_entry_bytes, min(@defaults[:max_entry_bytes], max_bytes))

    config = defaults |> Keyword.merge(opts) |> Map.new()

    for key <- [:max_entries, :max_bytes, :max_entry_bytes] do
      value = config[key]

      unless is_integer(value) and value > 0,
        do: raise(ArgumentError, "cache #{key} must be a positive integer")
    end

    if config.max_entry_bytes > config.max_bytes,
      do: raise(ArgumentError, "cache max_entry_bytes must not exceed max_bytes")

    %{config | query: query_policy!(config.query)}
  end

  def config!(_other), do: raise(ArgumentError, "cache must be a keyword list")

  defp query_policy!(policy) when policy in [:all, :ignore], do: policy

  defp query_policy!({kind, names}) when kind in [:only, :except] and is_list(names) do
    unless Enum.all?(names, &is_binary/1),
      do: raise(ArgumentError, "cache query parameter names must be strings")

    {kind, names}
  end

  defp query_policy!(_policy),
    do:
      raise(
        ArgumentError,
        "cache query must be :all, :ignore, {:only, names} or {:except, names}"
      )

  ## Request path

  @doc false
  # Returns what the proxy should do with this request. Telemetry for hits, stale hits and
  # misses is emitted here, in the request process.
  def lookup(name, conn) do
    case meta(name) do
      nil ->
        :disabled

      {config, counters, {generation, epoch}} ->
        ctx = %{
          name: name,
          config: config,
          counters: counters,
          epoch: {generation, :atomics.get(epoch, 1)},
          key: nil,
          token: nil,
          refresh: false
        }

        if conn.method in ["GET", "HEAD"],
          do: find(%{ctx | key: key(conn, config.query)}, conn.method),
          else: {:bypass, ctx}
    end
  rescue
    # The cache server restarted between reads. Serve this request as if it were off.
    ArgumentError -> :disabled
  end

  defp find(ctx, method) do
    entries = table(ctx.name, :entries)
    now = now()

    case :ets.lookup(entries, ctx.key) do
      [{key, entry, used, refresh_at, _bytes}] ->
        age = now - entry.stored_at

        cond do
          fresh?(entry, age) ->
            touch(entries, key, used, now)
            emit(ctx, :hit, %{age: age, bytes: entry.bytes}, key_meta(key))
            {:hit, entry}

          servable?(entry, age) ->
            touch(entries, key, used, now)
            emit(ctx, :stale, %{age: age, bytes: entry.bytes}, key_meta(key))
            {:stale, entry, refresh_at <= now, ctx}

          true ->
            miss(ctx, method)
        end

      [] ->
        miss(ctx, method)
    end
  end

  defp miss(ctx, method) do
    emit(ctx, :miss, %{}, key_meta(ctx.key))

    cond do
      # A HEAD response has no body to store. It goes to Node as it is.
      method == "HEAD" -> {:bypass, ctx}
      # This page wasn't cacheable last time, so don't make others wait on it.
      :ets.member(table(ctx.name, :passes), ctx.key) -> {:render, ctx}
      true -> {:miss, ctx}
    end
  end

  defp touch(entries, key, used, now) do
    if now - used >= @touch, do: :ets.update_element(entries, key, {3, now})
  end

  @doc false
  # Becomes the one render for this key, waits for the current one, or renders alone.
  def claim(ctx) do
    case GenServer.call(Frontman.cache(ctx.name), {:claim, ctx.key}, @wait) do
      {:leader, token} -> {:leader, %{ctx | token: token}}
      other -> other
    end
  catch
    # Timed out, or the cache stopped. Either way, render without it.
    :exit, _reason -> :render
  end

  @doc false
  def refresh(ctx, spec), do: GenServer.cast(Frontman.cache(ctx.name), {:refresh, ctx.key, spec})

  @doc false
  # Renders a page again in the background and stores the result. Runs in a pool task.
  def refresh_render(ctx, spec) do
    outcome =
      case Frontman.checkout(ctx.name) do
        {:error, _reason} ->
          {:skip, :unavailable}

        {:ok, worker} ->
          try do
            :get
            |> Finch.build("http://127.0.0.1:#{worker.port}#{spec.path}", spec.headers)
            |> Finch.stream_while(
              Frontman.finch(ctx.name),
              %{status: nil, capture: capture(ctx)},
              &collect/2,
              pool_timeout: 2_000,
              receive_timeout: 15_000
            )
            |> case do
              {:ok, acc} -> outcome(acc.capture, true)
              {:error, _error, acc} -> outcome(abort(acc.capture), false)
            end
          after
            Frontman.checkin(worker)
          end
      end

    finish(ctx, outcome)
  end

  defp collect({:status, status}, acc), do: {:cont, %{acc | status: status}}

  defp collect({:headers, headers}, %{capture: %{decision: nil}} = acc) do
    {capture, _headers} = capture_headers(acc.capture, "GET", acc.status, headers)
    continue(%{acc | capture: capture})
  end

  defp collect({:data, data}, acc),
    do: continue(%{acc | capture: capture_data(acc.capture, data)})

  defp collect(_other, acc), do: {:cont, acc}

  defp continue(%{capture: %{decision: {:store, _}}} = acc), do: {:cont, acc}
  defp continue(acc), do: {:halt, acc}

  ## Capturing a response

  @doc false
  # Per-attempt state for a response that may be stored. `nil` when the cache is off, so the
  # proxy's relay is unchanged.
  def capture(nil), do: nil
  def capture(ctx), do: %{ctx: ctx, decision: nil, headers: [], chunks: [], size: 0}

  @doc false
  # Decides from the status and headers whether the response can be stored, and returns the
  # headers to send downstream. The marker header never leaves Frontman.
  def capture_headers(nil, _method, _status, headers), do: {nil, headers}

  def capture_headers(capture, method, status, headers) do
    {markers, headers} = Enum.split_with(headers, &(elem(&1, 0) == @marker))

    case decide(method, status, markers, headers) do
      {:store, _directives} = decision ->
        headers = put_default(headers, "cache-control", "no-cache")
        stored = Enum.reject(headers, &(elem(&1, 0) in @unstored))
        {%{capture | decision: decision, headers: stored}, headers ++ [{@status_header, "miss"}]}

      decision ->
        {settle(%{capture | decision: decision}), headers}
    end
  end

  defp decide(method, status, markers, headers) do
    cond do
      method != "GET" -> if markers == [], do: :pass, else: {:skip, :method}
      status >= 500 -> {:skip, :error}
      status != 200 -> {:skip, :status}
      markers == [] -> {:skip, :not_marked}
      List.keymember?(headers, "set-cookie", 0) -> {:skip, :set_cookie}
      private?(headers) -> {:skip, :private}
      Enum.any?(tokens(headers, "vary"), &(&1 != "accept-encoding")) -> {:skip, :vary}
      Enum.any?(tokens(headers, "content-encoding"), &(&1 != "identity")) -> {:skip, :encoded}
      true -> directives(markers)
    end
  end

  defp private?(headers) do
    headers
    |> tokens("cache-control")
    |> Enum.any?(&(hd(String.split(&1, "=", parts: 2)) in ["private", "no-store"]))
  end

  defp tokens(headers, name) do
    for {^name, value} <- headers,
        token <- String.split(value, ","),
        token = token |> String.trim() |> String.downcase(),
        token != "",
        do: token
  end

  # `public` is required. `max-age` and `stale-while-revalidate` are optional, in seconds.
  defp directives(markers) do
    markers
    |> Enum.map_join(",", &elem(&1, 1))
    |> String.split(",")
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.reduce_while(%{}, fn
      "public", acc -> {:cont, Map.put(acc, :public, true)}
      "max-age=" <> value, acc -> seconds(value, :max_age, acc)
      "stale-while-revalidate=" <> value, acc -> seconds(value, :stale, acc)
      _unknown, _acc -> {:halt, :invalid}
    end)
    |> case do
      %{public: true, stale: _} = directives when not is_map_key(directives, :max_age) ->
        {:skip, :invalid_marker}

      %{public: true} = directives ->
        {:store, %{max_age: directives[:max_age], stale: Map.get(directives, :stale, 0)}}

      _invalid ->
        {:skip, :invalid_marker}
    end
  end

  defp seconds(value, key, acc) do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 -> {:cont, Map.put(acc, key, seconds * 1_000)}
      _invalid -> {:halt, :invalid}
    end
  end

  @doc false
  def capture_data(%{decision: {:store, _}} = capture, data) do
    size = capture.size + byte_size(data)

    if size > capture.ctx.config.max_entry_bytes,
      do: settle(%{capture | decision: {:skip, :too_large}, chunks: []}),
      else: %{capture | chunks: [capture.chunks | data], size: size}
  end

  def capture_data(capture, _data), do: capture

  @doc false
  # The response stopped part-way: the client left, or Node failed mid-stream.
  def abort(%{decision: {:store, _}} = capture),
    do: settle(%{capture | decision: {:skip, :aborted}, chunks: []})

  def abort(capture), do: capture

  # Waiters can start their own renders as soon as the leader knows it can't share.
  defp settle(%{decision: {:skip, _}, ctx: %{token: token} = ctx} = capture)
       when is_reference(token) do
    GenServer.cast(Frontman.cache(ctx.name), {:release, ctx.key, token})
    capture
  end

  defp settle(capture), do: capture

  @doc false
  def outcome(nil, _complete?), do: nil

  def outcome(%{decision: {:store, directives}} = capture, true),
    do: {:store, entry(capture, directives)}

  def outcome(%{decision: {:store, _}}, false), do: {:skip, :aborted}
  def outcome(%{decision: decision}, _complete?), do: decision

  defp entry(capture, directives) do
    body = IO.iodata_to_binary(capture.chunks)

    {etag, headers} =
      case List.keyfind(capture.headers, "etag", 0) do
        {"etag", etag} ->
          {etag, capture.headers}

        nil ->
          # Weak, so the adapter may still compress it, and one validator covers both encodings.
          hash = :crypto.hash(:sha256, body) |> Base.url_encode64(padding: false)
          etag = ~s(W/"#{binary_part(hash, 0, 27)}")
          {etag, capture.headers ++ [{"etag", etag}]}
      end

    %{
      headers: headers,
      body: body,
      etag: etag,
      stored_at: now(),
      max_age: directives.max_age,
      stale: directives.stale,
      bytes:
        byte_size(body) +
          Enum.reduce(headers, 0, &(byte_size(elem(&1, 0)) + byte_size(elem(&1, 1)) + &2))
    }
  end

  @doc false
  # Reports a finished render: telemetry for a skip, and the result to the cache server.
  def finish(ctx, outcome) do
    # A page render that ended without a response from Node, such as a 503 from admission.
    outcome = if is_nil(outcome) and ctx.key, do: {:skip, :unavailable}, else: outcome

    case outcome do
      {:skip, reason} -> emit(ctx, :skip, %{}, Map.put(key_meta(ctx.key), :reason, reason))
      _other -> :ok
    end

    if ctx.key && match?({kind, _} when kind in [:store, :skip], outcome) do
      GenServer.cast(
        Frontman.cache(ctx.name),
        {:complete, ctx.key, ctx.token, outcome, ctx.epoch, ctx.refresh}
      )
    end

    :ok
  end

  ## Serving

  @doc false
  def response(conn, entry, label) do
    age = div(max(now() - entry.stored_at, 0), 1_000)
    extra = [{"age", Integer.to_string(age)}, {@status_header, label}]

    if not_modified?(conn, entry.etag),
      do: {304, Enum.filter(entry.headers, &(elem(&1, 0) in @not_modified)) ++ extra, ""},
      else: {200, entry.headers ++ extra, entry.body}
  end

  # If-None-Match uses weak comparison (RFC 9110, section 13.1.2).
  defp not_modified?(conn, etag) do
    conn
    |> get_req_header("if-none-match")
    |> Enum.flat_map(&String.split(&1, ","))
    |> Enum.map(&String.trim/1)
    |> Enum.any?(&(&1 == "*" or opaque(&1) == opaque(etag)))
  end

  defp opaque("W/" <> tag), do: tag
  defp opaque(tag), do: tag

  ## Keys

  # Host and scheme are the ones Node is told, so a request can't fill an entry for one host
  # with a page rendered for another.
  defp key(conn, policy) do
    host = forwarded(conn, "x-forwarded-host") || forwarded(conn, "host") || conn.host
    scheme = forwarded(conn, "x-forwarded-proto") || to_string(conn.scheme)

    {String.downcase(scheme), String.downcase(host), conn.request_path,
     query_key(conn.query_string, policy)}
  end

  defp forwarded(conn, header) do
    case get_req_header(conn, header) do
      [] -> nil
      values -> Enum.join(values, ",")
    end
  end

  defp query_key("", _policy), do: ""
  defp query_key(_query, :ignore), do: ""

  defp query_key(query, policy) do
    query
    |> String.split("&", trim: true)
    |> Enum.map(&{param_name(&1), &1})
    |> Enum.filter(fn {name, _param} -> keep?(name, policy) end)
    # A stable sort, so repeated parameters keep their order.
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join("&", &elem(&1, 1))
  end

  defp keep?(_name, :all), do: true
  defp keep?(name, {:only, names}), do: name in names
  defp keep?(name, {:except, names}), do: name not in names

  defp param_name(param) do
    name = param |> String.split("=", parts: 2) |> hd()

    try do
      URI.decode_www_form(name)
    rescue
      ArgumentError -> name
    end
  end

  defp key_meta(nil), do: %{}
  defp key_meta({_scheme, host, path, query}), do: %{host: host, path: path, query: query}

  ## Invalidation and status

  @doc false
  def invalidate(name, opts) do
    match = matcher!(opts)
    GenServer.call(Frontman.cache(name), {:invalidate, match})
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  defp matcher!(opts) do
    unless Keyword.keyword?(opts), do: raise(ArgumentError, "invalidate expects a keyword list")

    case Keyword.keys(opts) -- [:host, :path, :prefix] do
      [] -> :ok
      [key | _] -> raise ArgumentError, "unknown invalidate option #{inspect(key)}"
    end

    host = Keyword.get(opts, :host)

    path =
      case {Keyword.get(opts, :path), Keyword.get(opts, :prefix)} do
        {path, nil} when is_binary(path) -> {:path, path}
        {nil, prefix} when is_binary(prefix) -> {:prefix, prefix}
        _other -> raise ArgumentError, "invalidate needs either a path or a prefix string"
      end

    unless is_nil(host) or is_binary(host), do: raise(ArgumentError, "host must be a string")
    %{host: host && String.downcase(host), path: path}
  end

  defp matches?({_scheme, host, path, _query}, match) do
    (is_nil(match.host) or host == match.host) and
      case match.path do
        {:path, wanted} -> path == wanted
        {:prefix, prefix} -> String.starts_with?(path, prefix)
      end
  end

  @doc false
  def stats(name) do
    case meta(name) do
      nil ->
        nil

      {config, counters, _epoch} ->
        count = &:counters.get(counters, @counters[&1])

        %{
          entries: :ets.info(table(name, :entries), :size),
          bytes: count.(:bytes),
          max_entries: config.max_entries,
          max_bytes: config.max_bytes,
          hits: count.(:hit),
          misses: count.(:miss),
          stale: count.(:stale),
          stores: count.(:store),
          skips: count.(:skip),
          evicted: count.(:evict),
          invalidated: count.(:invalidate)
        }
    end
  rescue
    ArgumentError -> nil
  end

  ## Server

  def start_link(opts) do
    name = Keyword.fetch!(opts, :name)
    GenServer.start_link(__MODULE__, opts, name: Frontman.cache(name))
  end

  @impl true
  def init(opts) do
    name = Keyword.fetch!(opts, :name)
    config = Keyword.fetch!(opts, :config)
    counters = :counters.new(map_size(@counters), [:write_concurrency])
    # A restarted cache counts invalidations from zero again. The generation tells its renders
    # apart from those that started under the cache it replaced.
    epoch = {make_ref(), :atomics.new(1, [])}

    # Entries are public so request processes can record use. Everything else is written here.
    :ets.new(table(name, :entries), [
      :set,
      :public,
      :named_table,
      read_concurrency: true,
      write_concurrency: true
    ])

    :ets.new(table(name, :passes), [:set, :protected, :named_table, read_concurrency: true])
    :ets.new(table(name, :meta), [:set, :protected, :named_table, read_concurrency: true])
    :ets.insert(table(name, :meta), {:meta, config, counters, epoch})

    {:ok,
     %{
       name: name,
       config: config,
       counters: counters,
       epoch: epoch,
       bytes: 0,
       flights: %{},
       monitors: %{}
     }}
  end

  @impl true
  def handle_call({:claim, key}, {pid, _tag} = from, state) do
    case state.flights do
      %{^key => flight} ->
        # A render that has outlived the wait can't help anyone arriving now.
        if now() - flight.started > @wait,
          do: {:reply, :render, state},
          else:
            {:noreply, put_in(state.flights[key], %{flight | waiters: [from | flight.waiters]})}

      _none ->
        case servable(state, key) do
          {:ok, entry} ->
            {:reply, {:entry, entry}, state}

          :error ->
            # Marked uncacheable since the caller looked, or this caller leads the render.
            if :ets.member(table(state.name, :passes), key) do
              {:reply, :render, state}
            else
              token = make_ref()
              {:reply, {:leader, token}, start_flight(state, key, pid, token, false)}
            end
        end
    end
  end

  def handle_call({:invalidate, match}, _from, state) do
    # Renders that started before this call must not store what they rendered.
    :atomics.add(elem(state.epoch, 1), 1, 1)

    keys =
      state.name
      |> table(:entries)
      |> :ets.select([{{:"$1", :_, :_, :_, :_}, [], [:"$1"]}])
      |> Enum.filter(&matches?(&1, match))

    state = Enum.reduce(keys, state, &delete(&2, &1))
    count(state, :invalidate, length(keys))

    metadata =
      %{name: state.name, host: match.host}
      |> Map.put(elem(match.path, 0), elem(match.path, 1))

    :telemetry.execute([:frontman, :cache, :invalidate], %{count: length(keys)}, metadata)
    {:reply, {:ok, length(keys)}, state}
  end

  @impl true
  def handle_cast({:release, key, token}, state) do
    {flight, state} = end_flight(state, key, token)
    reply_all(flight, :render)
    {:noreply, state}
  end

  def handle_cast({:complete, key, token, outcome, epoch, refresh}, state) do
    {flight, state} = end_flight(state, key, token)

    state =
      cond do
        # Rendered before an invalidation, or under a cache this one replaced: it may not
        # change anything, stored page or pass mark.
        epoch != current_epoch(state) ->
          reply_all(flight, :render)

          if match?({:store, _}, outcome),
            do: emit(state, :skip, %{}, Map.put(key_meta(key), :reason, :invalidated))

          state

        match?({:store, _}, outcome) ->
          {:store, entry} = outcome
          reply_all(flight, {:entry, entry})
          store(state, key, entry)

        true ->
          {:skip, reason} = outcome
          reply_all(flight, :render)
          skipped(state, key, reason, refresh)
      end

    {:noreply, state}
  end

  def handle_cast({:refresh, key, spec}, state) do
    case refreshable(state, key) do
      {:ok, stored_at} -> {:noreply, start_refresh(state, key, spec, stored_at)}
      :error -> {:noreply, state}
    end
  end

  # A cast can arrive late, after another refresh replaced the page or failed and set a retry
  # time. Only a copy that is still stale and due gets a refresh.
  defp refreshable(state, key) do
    now = now()

    with false <- Map.has_key?(state.flights, key),
         [{^key, entry, _used, refresh_at, _bytes}] <-
           :ets.lookup(table(state.name, :entries), key),
         age = now - entry.stored_at,
         true <- not fresh?(entry, age) and servable?(entry, age) and refresh_at <= now do
      {:ok, entry.stored_at}
    else
      _no -> :error
    end
  end

  defp start_refresh(state, key, spec, stored_at) do
    entries = table(state.name, :entries)
    token = make_ref()

    ctx = %{
      name: state.name,
      config: state.config,
      counters: state.counters,
      epoch: current_epoch(state),
      key: key,
      token: token,
      # The copy being refreshed, so a late result can't remove a newer one.
      refresh: stored_at
    }

    with true <- :ets.update_element(entries, key, {4, now() + @wait}),
         {:ok, pid} <- start_task(state.name, fn -> refresh_render(ctx, spec) end) do
      start_flight(state, key, pid, token, stored_at)
    else
      _failed -> state
    end
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitors, ref) do
      {nil, _monitors} ->
        {:noreply, state}

      {key, monitors} ->
        {flight, flights} = Map.pop(state.flights, key)
        reply_all(flight, :render)
        if flight.refresh, do: retry_later(state, key, flight.refresh)
        {:noreply, %{state | flights: flights, monitors: monitors}}
    end
  end

  # Waiters give up after @wait on their side. Let go of them here too, so a slow render
  # doesn't hold on to callers that have left. The render itself can still store its page.
  def handle_info({:expire, key, token}, state) do
    case state.flights do
      %{^key => %{token: ^token} = flight} ->
        reply_all(flight, :render)
        {:noreply, put_in(state.flights[key], %{flight | waiters: []})}

      _other ->
        {:noreply, state}
    end
  end

  defp start_task(name, fun) do
    Task.Supervisor.start_child(Frontman.tasks(name), fun)
  catch
    :exit, _reason -> :error
  end

  defp start_flight(state, key, pid, token, refresh) do
    ref = Process.monitor(pid)
    Process.send_after(self(), {:expire, key, token}, @wait)
    flight = %{token: token, monitor: ref, waiters: [], refresh: refresh, started: now()}

    %{
      state
      | flights: Map.put(state.flights, key, flight),
        monitors: Map.put(state.monitors, ref, key)
    }
  end

  defp end_flight(state, key, token) do
    case state.flights do
      %{^key => %{token: ^token} = flight} ->
        Process.demonitor(flight.monitor, [:flush])

        {flight,
         %{
           state
           | flights: Map.delete(state.flights, key),
             monitors: Map.delete(state.monitors, flight.monitor)
         }}

      _other ->
        {nil, state}
    end
  end

  defp reply_all(nil, _message), do: :ok
  defp reply_all(flight, message), do: Enum.each(flight.waiters, &GenServer.reply(&1, message))

  defp servable(state, key) do
    case :ets.lookup(table(state.name, :entries), key) do
      [{^key, entry, _used, _refresh_at, _bytes}] ->
        if servable?(entry, now() - entry.stored_at), do: {:ok, entry}, else: :error

      [] ->
        :error
    end
  end

  defp skipped(state, key, reason, refresh) when reason in @inconclusive do
    if refresh, do: retry_later(state, key, refresh)
    state
  end

  defp skipped(state, key, _reason, refresh) do
    passes = table(state.name, :passes)
    # Bounded without bookkeeping: past the entry limit, forget every pass at once.
    if :ets.info(passes, :size) >= state.config.max_entries, do: :ets.delete_all_objects(passes)
    :ets.insert(passes, {key})

    # A refresh that isn't cacheable means the page no longer is, if the copy it refreshed is
    # still the one stored. A visitor's render only replaces a copy that can't be served.
    cond do
      refresh -> if stored_at(state, key) == refresh, do: delete(state, key), else: state
      servable(state, key) == :error -> delete(state, key)
      true -> state
    end
  end

  defp retry_later(state, key, stored_at) do
    if stored_at(state, key) == stored_at,
      do: :ets.update_element(table(state.name, :entries), key, {4, now() + @retry})
  end

  defp stored_at(state, key) do
    case :ets.lookup(table(state.name, :entries), key) do
      [{^key, entry, _used, _refresh_at, _bytes}] -> entry.stored_at
      [] -> nil
    end
  end

  defp current_epoch(%{epoch: {generation, counter}}),
    do: {generation, :atomics.get(counter, 1)}

  # Headers count towards the bound too, so a body just under max_entry_bytes can still be
  # too big to keep.
  defp store(state, key, %{bytes: bytes}) when bytes > state.config.max_bytes do
    emit(state, :skip, %{}, Map.put(key_meta(key), :reason, :too_large))
    state
  end

  defp store(state, key, entry) do
    entries = table(state.name, :entries)

    previous =
      case :ets.lookup(entries, key) do
        [{_key, _entry, _used, _refresh_at, bytes}] -> bytes
        [] -> 0
      end

    # Monotonic time can be negative, so "refresh any time from now" is now, not 0.
    now = now()
    :ets.insert(entries, {key, entry, now, now, entry.bytes})
    :ets.delete(table(state.name, :passes), key)
    state = put_bytes(state, state.bytes - previous + entry.bytes)
    emit(state, :store, %{bytes: entry.bytes}, key_meta(key))
    evict(state, key)
  end

  # Past either bound, drop the least recently used entries until both are at 90%, so a full
  # cache sorts its entries once per many stores rather than on every one.
  defp evict(state, kept) do
    entries = table(state.name, :entries)
    %{max_entries: max_entries, max_bytes: max_bytes} = state.config
    size = :ets.info(entries, :size)

    if size > max_entries or state.bytes > max_bytes do
      low_entries = div(max_entries * 9, 10)
      low_bytes = div(max_bytes * 9, 10)

      {_size, bytes, removed, freed} =
        entries
        |> :ets.select([{{:"$1", :_, :"$2", :_, :"$3"}, [], [{{:"$2", :"$1", :"$3"}}]}])
        |> Enum.reject(&(elem(&1, 1) == kept))
        |> Enum.sort()
        |> Enum.reduce_while({size, state.bytes, 0, 0}, fn {_used, key, entry_bytes},
                                                           {size, bytes, removed, freed} ->
          if size > low_entries or bytes > low_bytes do
            :ets.delete(entries, key)

            {:cont, {size - 1, bytes - entry_bytes, removed + 1, freed + entry_bytes}}
          else
            {:halt, {size, bytes, removed, freed}}
          end
        end)

      count(state, :evict, removed)

      :telemetry.execute(
        [:frontman, :cache, :evict],
        %{count: removed, bytes: freed},
        %{name: state.name}
      )

      put_bytes(state, bytes)
    else
      state
    end
  end

  defp delete(state, key) do
    case :ets.take(table(state.name, :entries), key) do
      [{_key, _entry, _used, _refresh_at, bytes}] -> put_bytes(state, state.bytes - bytes)
      [] -> state
    end
  end

  defp put_bytes(state, bytes) do
    :counters.put(state.counters, @counters.bytes, bytes)
    %{state | bytes: bytes}
  end

  ## Helpers

  defp fresh?(entry, age), do: is_nil(entry.max_age) or age < entry.max_age
  defp servable?(entry, age), do: is_nil(entry.max_age) or age < entry.max_age + entry.stale

  defp meta(name) do
    meta = table(name, :meta)

    # A pool without a cache has no table. Checking first avoids raising on every request.
    with true <- :ets.whereis(meta) != :undefined,
         [{:meta, config, counters, epoch}] <- :ets.lookup(meta, :meta) do
      {config, counters, epoch}
    else
      _none -> nil
    end
  end

  defp table(name, :entries), do: Module.concat(name, CacheEntries)
  defp table(name, :passes), do: Module.concat(name, CachePasses)
  defp table(name, :meta), do: Module.concat(name, CacheMeta)

  defp put_default(headers, name, value),
    do: if(List.keymember?(headers, name, 0), do: headers, else: headers ++ [{name, value}])

  defp emit(source, event, measurements, metadata) do
    count(source, event, 1)

    :telemetry.execute(
      [:frontman, :cache, event],
      measurements,
      Map.put(metadata, :name, source.name)
    )
  end

  defp count(source, event, n), do: :counters.add(source.counters, @counters[event], n)

  defp now, do: System.monotonic_time(:millisecond)
end
