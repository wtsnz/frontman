defmodule Mix.Tasks.Frontman.Package do
  @shortdoc "Builds the frontend and bundles it with Node for a release"

  @moduledoc """
  Builds the frontend with a pinned Node and copies Node and the build into `priv`, so
  `mix release` ships both.

  The task:

    1. Downloads the official Node archive for this machine's OS and CPU from nodejs.org, or
       reuses a cached copy, and checks it against Node's published `SHASUMS256.txt`.
    2. Runs `npm ci` and the build in the frontend directory with that Node first on `PATH`.
       Node doesn't need to be installed.
    3. Copies the `node` binary and Node's license to `priv/node`, and the build output to
       `priv/frontend/.output`.

  It fails on a checksum mismatch, an unsupported platform, a failed npm command, or a build
  that writes no output. `priv` is only changed once the build has succeeded.

  Run it on the platform the release targets, for example in the release's build container.
  Node is downloaded for the machine the task runs on, and `npm ci` installs native packages
  for it too.

  ## Configuration

      # config/config.exs
      config :frontman, :package,
        node_version: "22.22.2"

  | Option | Default | Description |
  | --- | --- | --- |
  | `node_version` | required | Exact Node version, such as `"22.22.2"`. |
  | `frontend` | `"frontend"` | The directory with `package.json` and `package-lock.json`. |
  | `build` | `["run", "build"]` | npm arguments that build the frontend. |
  | `output` | `".output"` | The build's output directory, inside `frontend`. |
  | `node_destination` | `"priv/node"` | Where Node goes. The binary is `bin/node` inside it. |
  | `frontend_destination` | `"priv/frontend"` | Where the output directory is copied, keeping its name. |
  | `node_mirror` | `"https://nodejs.org/dist"` | Base URL of Node's releases, laid out like nodejs.org. |

  Paths are relative to the project root and must stay inside it. The task replaces
  `node_destination` and `frontend_destination/<output>` each run, and deletes the frontend's
  output directory before building.

  ## Command line options

    * `--node-version`, `--frontend`, `--output`, `--node-destination`,
      `--frontend-destination` and `--node-mirror` override the configuration.

  ## Cache

  Verified downloads are kept in `$FRONTMAN_CACHE_DIR`, or the user cache directory
  (`~/.cache/frontman` on Linux, `~/Library/Caches/frontman` on macOS). Cached archives are
  checked against their checksum again on every run.
  """

  use Mix.Task

  @switches [
    node_version: :string,
    frontend: :string,
    output: :string,
    node_destination: :string,
    frontend_destination: :string,
    node_mirror: :string
  ]

  @impl true
  def run(args) do
    {overrides, _rest} = OptionParser.parse!(args, strict: @switches)

    Application.get_env(:frontman, :package, [])
    |> Keyword.merge(overrides)
    |> Keyword.merge(
      root: File.cwd!(),
      cache_dir: cache_dir(),
      work_dir: Path.join(Mix.Project.build_path(), "frontman")
    )
    |> Frontman.Package.run()

    :ok
  end

  defp cache_dir do
    System.get_env("FRONTMAN_CACHE_DIR") || :filename.basedir(:user_cache, "frontman")
  end
end
