defmodule Frontman.Package do
  @moduledoc false
  # Builds the frontend with a pinned, checksum-verified Node and copies Node and the build into
  # the application's priv directory. `mix frontman.package` is the interface.

  @defaults [
    frontend: "frontend",
    build: ["run", "build"],
    output: ".output",
    node_destination: "priv/node",
    frontend_destination: "priv/frontend",
    node_mirror: "https://nodejs.org/dist"
  ]

  # The archive's only symlinks. OTP's tar extraction rejects them, so they are recreated.
  @links [
    {"npm", "../lib/node_modules/npm/bin/npm-cli.js"},
    {"npx", "../lib/node_modules/npm/bin/npx-cli.js"},
    {"corepack", "../lib/node_modules/corepack/dist/corepack.js"}
  ]

  @download_timeout 600_000

  @doc """
  Packages Node and the frontend build. Besides the task's options, `opts` needs `:root`,
  `:cache_dir` and `:work_dir`. Tests pass `:platform` to skip detection.
  """
  def run(opts) do
    opts = Keyword.merge(@defaults, opts)
    root = Keyword.fetch!(opts, :root)
    version = node_version!(opts[:node_version])
    platform = Keyword.get_lazy(opts, :platform, &platform!/0)
    frontend = Path.join(root, relative!(opts, :frontend))
    output = Path.join(frontend, relative!(opts, :output))
    node_destination = Path.join(root, relative!(opts, :node_destination))

    frontend_destination =
      Path.join([root, relative!(opts, :frontend_destination), Path.basename(output)])

    build = build!(opts[:build])

    File.regular?(Path.join(frontend, "package.json")) ||
      Mix.raise("No package.json in #{frontend}")

    archive = fetch!(version, platform, opts[:node_mirror], opts[:cache_dir])
    node = extract!(archive, Path.join(opts[:work_dir], Path.basename(archive, ".tar.gz")))

    # A stale build must not stand in for one that wrote nothing.
    File.rm_rf!(output)
    npm!(node, frontend, ["ci"])
    npm!(node, frontend, build)

    unless File.dir?(output) and File.ls!(output) != [],
      do: Mix.raise("The build didn't write #{output}")

    install_node!(node, node_destination)
    replace!(output, frontend_destination)

    Mix.shell().info([
      "Packaged Node v#{version} (#{platform}) in #{Path.relative_to(node_destination, root)} ",
      "and the build in #{Path.relative_to(frontend_destination, root)}"
    ])

    %{node: Path.join(node_destination, "bin/node"), output: frontend_destination}
  end

  @doc "Node's name for the platform, from `:os.type/0` and the system architecture."
  def platform!(os_type \\ :os.type(), arch \\ system_architecture()) do
    case {os_type, String.split(arch, "-")} do
      {{:unix, os}, [cpu | rest]} when os in [:linux, :darwin] ->
        if os == :linux and Enum.any?(rest, &String.starts_with?(&1, "musl")),
          do: unsupported!(arch, "Node publishes no official musl builds")

        "#{os}-#{cpu!(cpu, arch)}"

      _ ->
        unsupported!(arch, "Frontman packages Node for Linux and macOS")
    end
  end

  defp system_architecture, do: :erlang.system_info(:system_architecture) |> List.to_string()

  defp cpu!(cpu, _arch) when cpu in ["x86_64", "amd64"], do: "x64"
  defp cpu!(cpu, _arch) when cpu in ["aarch64", "arm64"], do: "arm64"
  defp cpu!(_cpu, arch), do: unsupported!(arch, "Frontman packages Node for x64 and arm64")

  defp unsupported!(arch, reason), do: Mix.raise("Unsupported platform #{arch}. #{reason}.")

  @doc "The expected SHA-256 of `file` in the text of a `SHASUMS256.txt`."
  def checksum!(sums, file) do
    Enum.find_value(String.split(sums, "\n"), fn line ->
      case String.split(line) do
        [sum, ^file] -> String.downcase(sum)
        _ -> nil
      end
    end) || Mix.raise("SHASUMS256.txt has no checksum for #{file}")
  end

  @doc "Raises unless `binary` has the SHA-256 published for `file` in `sums`."
  def verify!(binary, sums, file) do
    expected = checksum!(sums, file)
    actual = :crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)

    if actual != expected do
      Mix.raise("""
      #{file} doesn't match its published SHA-256.

      Expected: #{expected}
        Actual: #{actual}
      """)
    end

    :ok
  end

  # Returns the path of a verified archive in the cache, downloading it when it's missing or
  # fails verification. Only verified files enter the cache.
  defp fetch!(version, platform, mirror, cache_dir) do
    file = "node-v#{version}-#{platform}.tar.gz"
    dir = Path.join([cache_dir, "node", "v#{version}"])
    archive = Path.join(dir, file)
    sums_path = Path.join(dir, "SHASUMS256.txt")

    with {:ok, sums} <- File.read(sums_path),
         {:ok, binary} <- File.read(archive),
         :ok <- verify_cached(binary, sums, file) do
      archive
    else
      _ ->
        url = "#{String.trim_trailing(mirror, "/")}/v#{version}"
        sums = download!("#{url}/SHASUMS256.txt")
        binary = download!("#{url}/#{file}")
        verify!(binary, sums, file)
        File.mkdir_p!(dir)
        write_atomically!(sums_path, sums)
        write_atomically!(archive, binary)
        archive
    end
  end

  defp verify_cached(binary, sums, file) do
    verify!(binary, sums, file)
  rescue
    Mix.Error ->
      Mix.shell().info("Cached #{file} failed verification; downloading it again")
      :error
  end

  defp download!(url) do
    Mix.shell().info("Downloading #{url}")

    case Mix.Utils.read_path(url, timeout: @download_timeout) do
      {:ok, binary} -> binary
      :badpath -> Mix.raise("Couldn't download #{url}: not a URL or file")
      {_kind, message} -> Mix.raise("Couldn't download #{url}: #{message}")
    end
  end

  defp write_atomically!(path, binary) do
    temporary = "#{path}.#{System.unique_integer([:positive])}.tmp"
    File.write!(temporary, binary)
    File.rename!(temporary, path)
  end

  # Extracts the archive's regular files, so `node` and `npm` run from a fresh copy of exactly
  # the verified archive. Returns the Node directory.
  defp extract!(archive, destination) do
    archive = String.to_charlist(archive)
    name = destination |> Path.basename() |> String.to_charlist()

    files =
      case :erl_tar.table(archive, [:compressed, :verbose]) do
        {:ok, entries} -> for {path, :regular, _, _, _, _, _} <- entries, do: path
        {:error, reason} -> Mix.raise("Couldn't read #{archive}: #{inspect(reason)}")
      end

    if Enum.any?(files, &(not List.starts_with?(&1, name ++ ~c"/"))),
      do: Mix.raise("#{archive} has files outside #{name}/")

    parent = Path.dirname(destination)
    File.rm_rf!(destination)
    File.mkdir_p!(parent)

    case :erl_tar.extract(archive, [:compressed, cwd: String.to_charlist(parent), files: files]) do
      :ok -> :ok
      {:error, reason} -> Mix.raise("Couldn't extract #{archive}: #{inspect(reason)}")
    end

    for {link, target} <- @links,
        File.regular?(Path.join([destination, "bin", target])),
        do: File.ln_s!(target, Path.join([destination, "bin", link]))

    destination
  end

  # Runs npm with the packaged Node first on PATH, so scripts that call `node` or `npm` use it.
  defp npm!(node, frontend, args) do
    npm = Path.join(node, "lib/node_modules/npm/bin/npm-cli.js")
    File.regular?(npm) || Mix.raise("The Node archive has no npm at #{npm}")
    path = Enum.join([Path.join(node, "bin"), System.get_env("PATH", "")], ":")

    Mix.shell().info("Running npm #{Enum.join(args, " ")} in #{frontend}")

    {_, status} =
      System.cmd(Path.join(node, "bin/node"), [npm | args],
        cd: frontend,
        env: [{"PATH", path}],
        into: IO.stream(),
        stderr_to_stdout: true
      )

    status == 0 || Mix.raise("npm #{Enum.join(args, " ")} exited with status #{status}")
  end

  # Only the binary ships. npm is a build tool, not something the workers run.
  defp install_node!(node, destination) do
    File.rm_rf!(destination)
    File.mkdir_p!(Path.join(destination, "bin"))
    File.cp!(Path.join(node, "bin/node"), Path.join(destination, "bin/node"))
    File.chmod!(Path.join(destination, "bin/node"), 0o755)
    File.cp!(Path.join(node, "LICENSE"), Path.join(destination, "LICENSE"))
  end

  defp replace!(source, destination) do
    File.rm_rf!(destination)
    File.mkdir_p!(Path.dirname(destination))
    File.cp_r!(source, destination)
  end

  defp node_version!(version) when is_binary(version) do
    version = String.trim_leading(version, "v")

    if Regex.match?(~r/\A\d+\.\d+\.\d+\z/, version),
      do: version,
      else:
        Mix.raise("node_version must be an exact version such as \"22.22.2\", got: #{version}")
  end

  defp node_version!(nil) do
    Mix.raise("""
    Set the Node version to package, for example:

        config :frontman, :package, node_version: "22.22.2"
    """)
  end

  defp node_version!(other),
    do: Mix.raise("node_version must be a string, got: #{inspect(other)}")

  defp build!(args) when is_list(args) and args != [] do
    if Enum.all?(args, &is_binary/1),
      do: args,
      else: Mix.raise("build must be a list of npm arguments, got: #{inspect(args)}")
  end

  defp build!(other),
    do: Mix.raise("build must be a list of npm arguments, got: #{inspect(other)}")

  # Every configured path is replaced or deleted, so each must stay inside the project.
  defp relative!(opts, key) do
    value = Keyword.fetch!(opts, key)

    case is_binary(value) and Path.type(value) == :relative and Path.safe_relative(value) do
      {:ok, path} when path not in ["", "."] -> path
      _ -> Mix.raise("#{key} must be a relative path inside the project, got: #{inspect(value)}")
    end
  end
end
