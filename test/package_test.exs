defmodule Frontman.PackageTest do
  # The task test changes the working directory, the environment and application config.
  use ExUnit.Case, async: false
  import ExUnit.CaptureIO

  @version "1.2.3"
  @platform "linux-x64"
  @archive "node-v#{@version}-#{@platform}.tar.gz"

  # Stands in for npm: logs each call with the first PATH entry, and runs package.json scripts
  # through the shell, so a script can call `node` and `npm` from PATH.
  @npm """
  #!/usr/bin/env node
  const { execSync } = require("node:child_process");
  const fs = require("node:fs");
  const [command, script] = process.argv.slice(2);
  fs.appendFileSync("npm.log", `${command} ${script || ""} ${process.env.PATH.split(":")[0]}\\n`);
  if (command === "run") {
    execSync(JSON.parse(fs.readFileSync("package.json")).scripts[script], { stdio: "inherit" });
  }
  """

  @build ~s|node -e "require('fs').mkdirSync('.output/server', {recursive: true}); require('fs').writeFileSync('.output/server/index.mjs', 'ok')"|

  setup %{tmp_dir: tmp} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    root = Path.join(tmp, "app")
    mirror = Path.join(tmp, "mirror")
    File.mkdir_p!(Path.join(root, "frontend"))
    File.mkdir_p!(Path.join(mirror, "v#{@version}"))
    publish(tmp, mirror)
    frontend(root, %{"build" => "npm run write", "write" => @build})

    opts = [
      root: root,
      cache_dir: Path.join(tmp, "cache"),
      work_dir: Path.join(tmp, "work"),
      node_version: @version,
      node_mirror: mirror,
      platform: @platform
    ]

    %{root: root, mirror: mirror, opts: opts}
  end

  @moduletag :tmp_dir

  test "installs only the verified node binary and copies the build", %{root: root, opts: opts} do
    stale = Path.join(root, "priv/frontend/.output/stale.txt")
    File.mkdir_p!(Path.dirname(stale))
    File.write!(stale, "old")

    package(opts)

    node = Path.join(root, "priv/node/bin/node")
    assert File.read!(node) =~ "exec"
    assert File.stat!(node).mode |> Bitwise.band(0o111) != 0
    assert File.read!(Path.join(root, "priv/node/LICENSE")) == "Node license"
    assert File.ls!(Path.join(root, "priv/node")) |> Enum.sort() == ["LICENSE", "bin"]
    assert File.ls!(Path.join(root, "priv/node/bin")) == ["node"]
    assert File.read!(Path.join(root, "priv/frontend/.output/server/index.mjs")) == "ok"
    refute File.exists?(stale)

    # Both npm commands, and the nested `npm run`, ran with the packaged Node first on PATH.
    bin = Path.join(opts[:work_dir], "node-v#{@version}-#{@platform}/bin")

    assert File.read!(Path.join(root, "frontend/npm.log")) ==
             "ci  #{bin}\nrun build #{bin}\nrun write #{bin}\n"
  end

  test "reuses verified downloads and replaces a corrupt one", %{mirror: mirror, opts: opts} do
    package(opts)
    cached = Path.join([opts[:cache_dir], "node", "v#{@version}", @archive])
    assert File.regular?(cached)

    File.rename!(mirror, mirror <> ".offline")
    flush()
    package(opts)
    refute_received {:mix_shell, :info, ["Downloading " <> _]}

    File.write!(cached, "corrupt")
    File.rename!(mirror <> ".offline", mirror)
    package(opts)
    assert_received {:mix_shell, :info, ["Cached " <> _]}
    assert :crypto.hash(:sha256, File.read!(cached)) == archive_sha(mirror)
  end

  test "a checksum mismatch fails before anything is installed", %{root: root} = context do
    File.write!(
      Path.join(context.mirror, "v#{@version}/SHASUMS256.txt"),
      "#{String.duplicate("0", 64)}  #{@archive}\n"
    )

    assert_raise Mix.Error, ~r/doesn't match its published SHA-256/, fn ->
      package(context.opts)
    end

    refute File.exists?(Path.join(root, "priv"))
    refute File.exists?(Path.join(context.opts[:cache_dir], "node/v#{@version}/#{@archive}"))
  end

  test "a build that writes nothing fails, even with an earlier build present", context do
    %{root: root, opts: opts} = context
    frontend(root, %{"build" => "true"})
    File.mkdir_p!(Path.join(root, "frontend/.output/server"))
    File.write!(Path.join(root, "frontend/.output/server/index.mjs"), "stale")

    assert_raise Mix.Error, ~r/The build didn't write/, fn -> package(opts) end
    refute File.exists?(Path.join(root, "priv"))
  end

  test "a failing build fails the task", %{root: root, opts: opts} do
    frontend(root, %{"build" => "exit 3"})
    assert_raise Mix.Error, ~r/npm run build exited with status/, fn -> package(opts) end
    refute File.exists?(Path.join(root, "priv"))
  end

  test "options are validated before downloading", %{opts: opts} do
    assert_raise Mix.Error, ~r/config :frontman, :package/, fn ->
      package(Keyword.delete(opts, :node_version))
    end

    assert_raise Mix.Error, ~r/exact version/, fn ->
      package(Keyword.put(opts, :node_version, "22"))
    end

    for path <- ["../elsewhere", "/tmp/priv", ".", "priv/../../x"] do
      assert_raise Mix.Error, ~r/relative path inside the project/, fn ->
        package(Keyword.put(opts, :node_destination, path))
      end
    end

    assert_raise Mix.Error, ~r/list of npm arguments/, fn ->
      package(Keyword.put(opts, :build, "npm run build"))
    end

    refute_received {:mix_shell, :info, ["Downloading " <> _]}
  end

  test "the task reads config, takes command line overrides and uses the cache directory",
       %{root: root, mirror: mirror, tmp_dir: tmp} do
    platform = Frontman.Package.platform!()
    publish(tmp, mirror, platform)
    cache = Path.join(tmp, "task-cache")
    previous = Application.get_env(:frontman, :package)

    on_exit(fn ->
      System.delete_env("FRONTMAN_CACHE_DIR")

      if previous,
        do: Application.put_env(:frontman, :package, previous),
        else: Application.delete_env(:frontman, :package)
    end)

    System.put_env("FRONTMAN_CACHE_DIR", cache)

    Application.put_env(:frontman, :package,
      node_version: @version,
      node_mirror: mirror,
      frontend: "missing"
    )

    capture_io(fn ->
      File.cd!(root, fn ->
        Mix.Task.rerun(
          "frontman.package",
          ~w(--frontend frontend --node-destination priv/runtime)
        )
      end)
    end)

    assert File.regular?(Path.join(root, "priv/runtime/bin/node"))
    assert File.regular?(Path.join(root, "priv/frontend/.output/server/index.mjs"))

    assert File.regular?(
             Path.join(cache, "node/v#{@version}/node-v#{@version}-#{platform}.tar.gz")
           )
  end

  test "maps OTP's platform to Node's archive names" do
    assert Frontman.Package.platform!({:unix, :linux}, "x86_64-pc-linux-gnu") == "linux-x64"

    assert Frontman.Package.platform!({:unix, :linux}, "aarch64-unknown-linux-gnu") ==
             "linux-arm64"

    assert Frontman.Package.platform!({:unix, :darwin}, "aarch64-apple-darwin") == "darwin-arm64"

    assert Frontman.Package.platform!({:unix, :darwin}, "x86_64-apple-darwin23.0.0") ==
             "darwin-x64"

    for {os, arch} <- [
          {{:unix, :linux}, "x86_64-pc-linux-musl"},
          {{:unix, :linux}, "armv7l-unknown-linux-gnueabihf"},
          {{:unix, :linux}, "arm-unknown-linux-gnueabihf"},
          {{:unix, :freebsd}, "x86_64-unknown-freebsd14.0"},
          {{:win32, :nt}, "win32"}
        ] do
      assert_raise Mix.Error, ~r/Unsupported platform/, fn ->
        Frontman.Package.platform!(os, arch)
      end
    end
  end

  test "reads a file's checksum from SHASUMS256.txt" do
    sums = """
    #{String.duplicate("a", 64)}  node-v1.2.3-linux-x64.tar.xz
    #{String.duplicate("B", 64)}  node-v1.2.3-linux-x64.tar.gz
    """

    assert Frontman.Package.checksum!(sums, "node-v1.2.3-linux-x64.tar.gz") ==
             String.duplicate("b", 64)

    assert_raise Mix.Error, ~r/no checksum for node-v1.2.3-linux-arm64.tar.gz/, fn ->
      Frontman.Package.checksum!(sums, "node-v1.2.3-linux-arm64.tar.gz")
    end

    assert :ok = Frontman.Package.verify!("data", sha_line("data", "f"), "f")

    assert_raise Mix.Error, fn ->
      Frontman.Package.verify!("tampered", sha_line("data", "f"), "f")
    end
  end

  defp package(opts) do
    capture_io(fn -> send(self(), {:result, Frontman.Package.run(opts)}) end)
    assert_received {:result, result}
    result
  end

  defp flush do
    receive do
      {:mix_shell, _, _} -> flush()
    after
      0 -> :ok
    end
  end

  defp frontend(root, scripts) do
    dir = Path.join(root, "frontend")
    File.write!(Path.join(dir, "package.json"), Jason.encode!(%{name: "app", scripts: scripts}))
    File.rm(Path.join(dir, "npm.log"))
  end

  # Publishes a fake Node archive and its SHASUMS256.txt, laid out like nodejs.org/dist.
  defp publish(tmp, mirror, platform \\ @platform) do
    source = Path.join(tmp, "node-source-#{platform}")
    archive_name = "node-v#{@version}-#{platform}.tar.gz"
    real_node = System.find_executable("node") || flunk("the tests need node on PATH")
    files = %{"bin/node" => "#!/bin/sh\nexec #{real_node} \"$@\"\n", "LICENSE" => "Node license"}

    files =
      Map.merge(files, %{
        "lib/node_modules/npm/bin/npm-cli.js" => @npm,
        "lib/node_modules/npm/bin/npx-cli.js" => "#!/usr/bin/env node\n"
      })

    entries =
      for {path, contents} <- files do
        file = Path.join(source, path)
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, contents)
        if String.contains?(path, "bin/"), do: File.chmod!(file, 0o755)
        {~c"node-v#{@version}-#{platform}/#{path}", String.to_charlist(file)}
      end

    archive = Path.join([mirror, "v#{@version}", archive_name])
    :ok = :erl_tar.create(String.to_charlist(archive), entries, [:compressed])

    File.write!(
      Path.join([mirror, "v#{@version}", "SHASUMS256.txt"]),
      sha_line("other", "node-v#{@version}-#{platform}.tar.xz") <>
        sha_line(File.read!(archive), archive_name)
    )
  end

  defp archive_sha(mirror),
    do: :crypto.hash(:sha256, File.read!(Path.join([mirror, "v#{@version}", @archive])))

  defp sha_line(binary, file),
    do: "#{:crypto.hash(:sha256, binary) |> Base.encode16(case: :lower)}  #{file}\n"
end
