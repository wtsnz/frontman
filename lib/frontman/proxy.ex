defmodule Frontman.Proxy do
  @moduledoc """
  Streams HTTP requests through a supervised frontend worker pool.

  Phoenix owns every public request. Backend paths continue to the router; everything else is
  streamed to the least busy ready worker. The proxy runs before `Plug.Parsers`, so server
  function bodies reach Node unchanged. When the pool has a `cache`, pages Node marked
  cacheable are served from memory; see the README's page cache section.
  """
  @behaviour Plug

  import Plug.Conn
  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  alias Frontman, as: Frontend
  alias Frontman.Cache

  @hop_by_hop ~w(connection keep-alive proxy-authenticate proxy-authorization proxy-connection
                 te trailer transfer-encoding upgrade)
  @max_body 8_000_000
  @unavailable "The frontend is temporarily unavailable. Please retry in a moment."

  @impl true
  def init(opts) do
    Keyword.fetch!(opts, :name)
    opts
  end

  @impl true
  def call(conn, opts) do
    conn = put_private(conn, :frontman, opts)

    cond do
      not Keyword.get(opts, :enabled, true) ->
        conn

      backend_path?(conn.request_path, opts) ->
        conn

      String.starts_with?(conn.request_path, "/__frontend/") ->
        conn |> send_resp(404, "") |> halt()

      true ->
        conn |> serve() |> halt()
    end
  end

  # Without a configured cache this is `proxy/1`, unchanged.
  defp serve(conn) do
    case Cache.lookup(Keyword.fetch!(conn.private.frontman, :name), conn) do
      :disabled ->
        proxy(conn)

      {:hit, entry} ->
        send_cached(conn, entry, "hit")

      {:stale, entry, refresh?, ctx} ->
        if refresh?, do: Cache.refresh(ctx, refresh_spec(conn))
        send_cached(conn, entry, "stale")

      {:miss, ctx} ->
        case Cache.claim(ctx) do
          {:entry, entry} -> send_cached(conn, entry, "hit")
          {:leader, ctx} -> render(conn, ctx)
          :render -> render(conn, ctx)
        end

      {kind, ctx} when kind in [:render, :bypass] ->
        render(conn, ctx)
    end
  end

  # Proxies as usual, capturing the response, then reports how it went. A leader that never
  # reports would leave its waiters to time out.
  defp render(conn, ctx) do
    ctx = verify(conn, ctx)
    conn = conn |> put_private(:frontman_cache, ctx) |> proxy()
    Cache.finish(ctx, conn.private[:frontman_cache_outcome])
    conn
  catch
    kind, reason ->
      Cache.finish(ctx, {:skip, :aborted})
      :erlang.raise(kind, reason, __STACKTRACE__)
  end

  # Debug mode checks a GET page rendered with the visitor's credentials against one without.
  defp verify(%{method: "GET"} = conn, %{key: key} = ctx) when key != nil do
    if Cache.debug?(ctx) and
         Enum.any?(["cookie", "authorization"], &(get_req_header(conn, &1) != [])),
       do: %{ctx | verify: refresh_spec(conn)},
       else: ctx
  end

  defp verify(_conn, ctx), do: ctx

  defp send_cached(conn, entry, label) do
    {status, headers, body} = Cache.response(conn, entry, label)
    request_id = Enum.filter(conn.resp_headers, &(elem(&1, 0) == "x-request-id"))
    # The adapter drops the body for HEAD but keeps its length.
    send_resp(%{conn | resp_headers: request_id ++ headers}, status, body)
  end

  # A background refresh renders as an anonymous visitor: no cookies, credentials or validators.
  defp refresh_spec(conn) do
    headers =
      conn
      |> request_headers()
      |> Enum.reject(fn {name, _value} ->
        name in ["cookie", "authorization", "if-none-match", "if-modified-since"]
      end)

    %{path: conn.request_path <> query(conn), headers: headers}
  end

  defp backend_path?(path, opts),
    do: Enum.any?(Keyword.get(opts, :pass_through, []), &String.starts_with?(path, &1))

  defp proxy(conn) do
    # Reserve before reading the body: overload cannot cause unbounded body buffering.
    case checkout(conn, []) do
      {:error, _reason} ->
        unavailable(conn)

      {:ok, worker} ->
        result =
          try do
            case read_full_body(conn, []) do
              {:ok, body, conn} -> {:response, attempt(conn, worker, body), conn, body}
              {:too_large, conn} -> {:too_large, conn}
            end
          after
            Frontend.checkin(worker)
          end

        # Answer on the conn that read the body. The adapter tracks the body on it; the earlier
        # one would leave the body unread and corrupt the next request on the connection.
        case result do
          {:response, response, conn, body} ->
            finish(response, conn, body, [worker.pid])

          {:too_large, conn} ->
            conn |> put_resp_header("connection", "close") |> send_resp(413, "")
        end
    end
  end

  defp checkout(conn, excluded),
    do: Frontend.checkout(Keyword.fetch!(conn.private.frontman, :name), excluded)

  defp read_full_body(conn, chunks) do
    case read_body(conn, length: @max_body) do
      {:ok, chunk, conn} -> finish_body(conn, [chunks, chunk])
      {:more, chunk, conn} -> read_more(conn, [chunks, chunk])
      # The body is left part-read, so the 413 closes the connection.
      {:error, _reason} -> {:too_large, conn}
    end
  end

  defp read_more(conn, chunks) do
    if IO.iodata_length(chunks) > @max_body,
      do: {:too_large, conn},
      else: read_full_body(conn, chunks)
  end

  defp finish_body(conn, chunks) do
    if IO.iodata_length(chunks) > @max_body,
      do: {:too_large, conn},
      else: {:ok, IO.iodata_to_binary(chunks), conn}
  end

  defp forward(conn, body, excluded) do
    case checkout(conn, excluded) do
      {:error, _reason} ->
        unavailable(conn)

      {:ok, worker} ->
        result =
          try do
            attempt(conn, worker, body)
          after
            Frontend.checkin(worker)
          end

        # Release the previous attempt before reserving another worker.
        finish(result, conn, body, [worker.pid | excluded])
    end
  end

  defp attempt(conn, worker, body) do
    Tracer.with_span "frontend.proxy", %{
      kind: :client,
      attributes: %{"frontend.worker" => worker.index}
    } do
      conn
      |> request(worker, body)
      |> Finch.stream_while(
        Frontend.finch(Keyword.fetch!(conn.private.frontman, :name)),
        %{conn: conn, sent: false, cache: Cache.capture(conn.private[:frontman_cache])},
        &relay/2,
        pool_timeout: 2_000,
        receive_timeout: 15_000
      )
      |> record_status()
    end
  end

  defp request(conn, worker, body) do
    url = "http://127.0.0.1:#{worker.port}#{conn.request_path}#{query(conn)}"
    Finch.build(conn.method, url, :otel_propagator_text_map.inject(request_headers(conn)), body)
  end

  defp query(%{query_string: ""}), do: ""
  defp query(conn), do: "?" <> conn.query_string

  defp request_headers(conn) do
    forwarded_for =
      [get_req_header(conn, "x-forwarded-for"), [conn.remote_ip |> :inet.ntoa() |> to_string()]]
      |> Enum.concat()
      |> Enum.join(", ")

    conn.req_headers
    |> Enum.reject(fn {name, _value} ->
      name in @hop_by_hop or name in ["content-length", "x-forwarded-for"]
    end)
    |> Kernel.++([{"x-forwarded-for", forwarded_for}])
    |> put_default("x-forwarded-proto", to_string(conn.scheme))
    # The Host header keeps a non-default port, which `conn.host` drops. The frontend needs it
    # to rebuild the public origin, for example `localhost:4000` in development.
    |> put_default("x-forwarded-host", conn |> get_req_header("host") |> List.first(conn.host))
    |> drop_validators(conn)
  end

  # A cache fill needs Node's full page, not a 304 meant for one client.
  defp drop_validators(headers, %{method: "GET", private: %{frontman_cache: _ctx}}),
    do: Enum.reject(headers, &(elem(&1, 0) in ["if-none-match", "if-modified-since"]))

  defp drop_validators(headers, _conn), do: headers

  defp put_default(headers, name, value) do
    if List.keymember?(headers, name, 0), do: headers, else: headers ++ [{name, value}]
  end

  defp record_status({:ok, %{status: status}} = result) do
    Tracer.set_attribute("http.response.status_code", status)
    result
  end

  defp record_status({:error, error, _acc} = result) do
    Tracer.set_status(OpenTelemetry.status(:error, Exception.message(error)))
    result
  end

  defp record_status(result), do: result

  defp relay({:status, status}, acc), do: {:cont, Map.put(acc, :status, status)}

  defp relay({:headers, headers}, %{sent: false, conn: conn} = acc) do
    headers = Enum.reject(headers, fn {name, _} -> name in ["content-length" | @hop_by_hop] end)
    {cache, headers} = Cache.capture_headers(acc.cache, conn.method, acc.status, headers)
    request_id = Enum.filter(conn.resp_headers, &(elem(&1, 0) == "x-request-id"))
    conn = %{conn | resp_headers: request_id ++ headers}
    acc = %{acc | cache: cache}

    if bodiless?(conn.method, acc.status) do
      {:cont, %{acc | conn: conn}}
    else
      {:cont, %{acc | conn: send_chunked(conn, acc.status), sent: true}}
    end
  end

  # Trailers and repeated header blocks are not forwarded.
  defp relay({:headers, _headers}, acc), do: {:cont, acc}
  defp relay({:trailers, _trailers}, acc), do: {:cont, acc}

  defp relay({:data, data}, %{sent: true} = acc) do
    case chunk(acc.conn, data) do
      {:ok, conn} -> {:cont, %{acc | conn: conn, cache: Cache.capture_data(acc.cache, data)}}
      # The browser went away; halting also cancels the upstream request.
      {:error, _reason} -> {:halt, %{acc | cache: Cache.abort(acc.cache)}}
    end
  end

  defp relay({:data, _data}, acc), do: {:cont, acc}

  defp bodiless?(method, status), do: method == "HEAD" or status in [204, 304] or status < 200

  defp finish({:ok, %{sent: true, conn: conn} = acc}, _conn, _body, _excluded),
    do: settle(conn, acc.cache, true)

  defp finish({:ok, %{conn: conn, status: status} = acc}, _conn, _body, _excluded),
    do: conn |> settle(acc.cache, true) |> send_resp(status, "")

  defp finish({:error, error, %{sent: false}}, conn, body, excluded) do
    if retryable?(error, conn.method) do
      forward(conn, body, excluded)
    else
      Logger.warning("frontend proxy failed before response: #{Exception.message(error)}")
      unavailable(conn)
    end
  end

  defp finish({:error, error, %{sent: true, conn: sent} = acc}, _conn, _body, _excluded) do
    Logger.warning("frontend proxy failed mid-response: #{Exception.message(error)}")
    settle(sent, acc.cache, false)
  end

  # Records what the cache can do with the response, for `render/2` to report.
  defp settle(conn, nil, _complete?), do: conn

  defp settle(conn, cache, complete?),
    do: put_private(conn, :frontman_cache_outcome, Cache.outcome(cache, complete?))

  # A refused connection never reached Node, so any method can move to another worker. A closed
  # connection may have delivered the request, so only safe methods retry. Each attempt excludes
  # the failed worker, which bounds retries to the pool size.
  defp retryable?(%Finch.TransportError{reason: :econnrefused}, _method), do: true

  defp retryable?(%Finch.TransportError{reason: :closed}, method),
    do: method in ["GET", "HEAD"]

  defp retryable?(_error, _method), do: false

  defp unavailable(conn) do
    conn
    |> put_resp_header("retry-after", "2")
    |> put_resp_content_type("text/plain")
    |> send_resp(503, @unavailable)
  end
end
