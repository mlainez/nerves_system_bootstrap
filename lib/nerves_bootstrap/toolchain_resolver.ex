defmodule NervesBootstrap.ToolchainResolver do
  @moduledoc """
  Resolves toolchain URLs from GitHub releases API, with fallback mechanisms
  for cases where the API is unavailable.
  """

  @arch_mapping %{
    :nerves_toolchain_aarch64_nerves_linux_gnu => "aarch64_nerves_linux_gnu",
    :nerves_toolchain_armv7_nerves_linux_gnueabihf => "armv7_nerves_linux_gnueabihf",
    :nerves_toolchain_x86_64_nerves_linux_musl => "x86_64_nerves_linux_musl",
    :nerves_toolchain_riscv64_nerves_linux_gnu => "riscv64_nerves_linux_gnu",
    :nerves_toolchain_armv6_nerves_linux_gnueabihf => "armv6_nerves_linux_gnueabihf",
    :nerves_toolchain_armv5_nerves_linux_musleabi => "armv5_nerves_linux_musleabi",
    :nerves_toolchain_armv7_nerves_linux_musleabihf => "armv7_nerves_linux_musleabihf",
    :nerves_toolchain_aarch64_nerves_linux_musl => "aarch64_nerves_linux_musl",
    :nerves_toolchain_x86_64_nerves_linux_gnu => "x86_64_nerves_linux_gnu",
    :nerves_toolchain_riscv64_nerves_linux_musl => "riscv64_nerves_linux_musl",
    :nerves_toolchain_i586_nerves_linux_gnu => "i586_nerves_linux_gnu",
    :nerves_toolchain_mipsel_nerves_linux_musl => "mipsel_nerves_linux_musl"
  }

  @doc """
  Gets toolchain URL from GitHub releases API.
  """
  def get_toolchain_url(toolchain_name, version) do
    Mix.shell().info(
      "🔍 Fetching toolchain URL from GitHub releases for #{toolchain_name} v#{version}"
    )

    get_toolchain_url_from_github(toolchain_name, version)
  end

  @doc """
  Finds a release matching the requested version with flexible matching.
  Supports partial version matching (e.g., "14.2" matches "v14.2.0").
  """
  def find_matching_release(releases, version_number) do
    # First try exact match
    exact_match =
      Enum.find(releases, fn release ->
        release["tag_name"] == "v#{version_number}"
      end)

    if exact_match do
      exact_match
    else
      # Try partial match - find releases that start with the version
      partial_match =
        Enum.find(releases, fn release ->
          tag = release["tag_name"]
          # Remove 'v' prefix and check if it starts with the version number
          case String.replace_prefix(tag, "v", "") do
            # No 'v' prefix found
            ^tag -> false
            version_part -> String.starts_with?(version_part, version_number)
          end
        end)

      partial_match
    end
  end

  defp get_toolchain_url_from_github(toolchain_name, version) do
    # Extract version number from requirement string like "~> 14.2"
    version_number =
      case version do
        "~> " <> v -> v
        v -> v
      end

    arch_name = @arch_mapping[toolchain_name]

    unless arch_name do
      Mix.raise("Unknown toolchain: #{toolchain_name}")
    end

    # Fetch releases from GitHub API
    url = "https://api.github.com/repos/nerves-project/toolchains/releases?per_page=10"

    case fetch_github_releases(url) do
      {:ok, releases} when is_list(releases) ->
        Mix.shell().info(
          "🔍 Searching for release v#{version_number} in #{length(releases)} releases..."
        )

        # Find the release matching our version with flexible matching
        target_release = find_matching_release(releases, version_number)

        unless target_release do
          available_versions = Enum.map(releases, & &1["tag_name"]) |> Enum.join(", ")
          Mix.shell().error("❌ Could not find release matching v#{version_number}")
          Mix.shell().info("📋 Available releases: #{available_versions}")
          Mix.shell().info("🔄 Falling back to environment variable method...")
          get_fallback_url(toolchain_name, version)
        else
          Mix.shell().info("✅ Found release #{target_release["tag_name"]}")

          # Find the asset matching our architecture and linux_x86_64 platform
          target_asset =
            Enum.find(target_release["assets"], fn asset ->
              asset_name = asset["name"]

              String.contains?(asset_name, arch_name) and
                String.contains?(asset_name, "linux_x86_64") and
                String.ends_with?(asset_name, ".tar.xz")
            end)

          unless target_asset do
            available_assets = Enum.map(target_release["assets"], & &1["name"]) |> Enum.join(", ")

            Mix.shell().error(
              "❌ Could not find #{arch_name}-linux_x86_64 toolchain in release #{target_release["tag_name"]}"
            )

            Mix.shell().info("📋 Available assets: #{available_assets}")
            Mix.shell().info("🔄 Falling back to environment variable method...")
            get_fallback_url(toolchain_name, version)
          else
            Mix.shell().info("✅ Found toolchain: #{target_asset["name"]}")
            target_asset["browser_download_url"]
          end
        end

      {:ok, _} ->
        Mix.shell().error("❌ GitHub API returned invalid format (not a list)")
        Mix.shell().info("🔄 Falling back to environment variable method...")
        get_fallback_url(toolchain_name, version)

      {:error, reason} ->
        Mix.shell().error("❌ Failed to fetch GitHub releases: #{reason}")
        Mix.shell().info("🔄 Falling back to environment variable method...")
        get_fallback_url(toolchain_name, version)
    end
  end

  defp fetch_github_releases(url) do
    try do
      # Use req if available, otherwise fall back to curl
      case Application.ensure_all_started(:req) do
        {:ok, _} ->
          case Req.get(url, headers: [{"User-Agent", "nerves-system-bootstrap"}]) do
            {:ok, %{status: 200, body: body}} when is_binary(body) ->
              case Jason.decode(body) do
                {:ok, data} when is_list(data) ->
                  {:ok, data}

                {:ok, data} ->
                  {:error, "Expected list but got: #{inspect(data)}"}

                {:error, reason} ->
                  {:error, "JSON decode error: #{inspect(reason)}"}
              end

            {:ok, %{status: 200, body: body}} when is_list(body) ->
              # Body is already parsed JSON
              {:ok, body}

            {:ok, %{status: status}} ->
              {:error, "HTTP #{status}"}

            {:error, reason} ->
              {:error, "Request failed: #{inspect(reason)}"}
          end

        {:error, _} ->
          # Fallback to curl if req is not available
          case System.cmd("curl", ["-s", "-H", "User-Agent: nerves-system-bootstrap", url]) do
            {response, 0} ->
              case Jason.decode(response) do
                {:ok, data} when is_list(data) ->
                  {:ok, data}

                {:ok, data} ->
                  {:error, "Expected list but got: #{inspect(data)}"}

                {:error, reason} ->
                  {:error, "JSON decode error: #{inspect(reason)}"}
              end

            {error, exit_code} ->
              {:error, "curl failed (#{exit_code}): #{error}"}
          end
      end
    rescue
      e -> {:error, "Exception: #{inspect(e)}"}
    end
  end

  defp get_fallback_url(toolchain_name, version) do
    Mix.shell().info("⚠️ Using fallback URL generation method")
    Mix.shell().info("💡 This requires setting environment variables with the correct hashes")

    # Extract version number from requirement string like "~> 14.2"
    version_number =
      case version do
        "~> " <> v -> v
        v -> v
      end

    arch_name = @arch_mapping[toolchain_name]

    # Determine the required hash environment variable
    hash_env_var =
      if String.contains?(to_string(toolchain_name), "musl") do
        "NERVES_MUSL_HASH"
      else
        "NERVES_GLIBC_HASH"
      end

    # Get hash from environment variable - fail if not provided
    hash = System.get_env(hash_env_var)

    if is_nil(hash) do
      Mix.raise("""
      Missing required environment variable: #{hash_env_var}

      GitHub API failed, falling back to manual hash configuration.
      To find the correct hash for #{toolchain_name} v#{version_number}:
      1. Visit https://github.com/nerves-project/toolchains/releases/tag/v#{version_number}
      2. Find the filename containing '#{arch_name}-linux_'
      3. Extract the hash from the filename (format: ...VERSION-HASH.tar.xz)
      4. Set: export #{hash_env_var}=<hash>

      Example: export #{hash_env_var}=C3B80E7
      """)
    end

    host_arch =
      case :erlang.system_info(:system_architecture) |> List.to_string() do
        "x86_64" <> _ -> "x86_64"
        "aarch64" <> _ -> "aarch64"
        _ -> "x86_64"
      end

    url =
      "https://github.com/nerves-project/toolchains/releases/download/v#{version_number}/nerves_toolchain_#{arch_name}-linux_#{host_arch}-#{version_number}-#{hash}.tar.xz"

    Mix.shell().info("🔗 Generated fallback URL: #{url}")
    url
  end
end
