defmodule NervesBootstrap.BuildrootManager do
  @moduledoc """
  Handles Buildroot repository management, including downloading, path resolution,
  and validation of Buildroot configurations.
  """

  @default_buildroot_url "https://github.com/buildroot/buildroot.git"

  @doc """
  Determines the Buildroot path from options, downloading if necessary.
  """
  def determine_buildroot(opts) do
    cond do
      buildroot = opts[:buildroot] ->
        Path.expand(buildroot)

      true ->
        url = opts[:"buildroot-url"] || @default_buildroot_url
        path = "buildroot"
        download_buildroot(url, path)
        Path.expand(path)
    end
  end

  @doc """
  Downloads Buildroot from the specified URL to the target path.
  Uses the same version as nerves_system_br.
  """
  def download_buildroot(url, path) do
    unless File.exists?(path) do
      version = get_nerves_br_version()
      Mix.shell().info("📥 Downloading Buildroot #{version} from #{url}...")
      {_, 0} = System.cmd("git", ["clone", "--branch", version, "--depth", "1", url, path])
      Mix.shell().info("✅ Buildroot #{version} downloaded to #{path}")
    end
  end

  @doc """
  Gets the Buildroot version used by nerves_system_br.
  """
  def get_nerves_br_version do
    nerves_br_path = Path.join([File.cwd!(), "deps", "nerves_system_br"])
    create_build_script = Path.join(nerves_br_path, "create-build.sh")

    if File.exists?(create_build_script) do
      create_build_script
      |> File.read!()
      |> extract_buildroot_version()
    else
      Mix.shell().info("⚠️ nerves_system_br not found, using default version 2025.05")
      "2025.05"
    end
  end

  defp extract_buildroot_version(script_content) do
    case Regex.run(~r/NERVES_BR_VERSION=(.+)/, script_content) do
      [_, version] -> String.trim(version)
      _ ->
        Mix.shell().info("⚠️ Could not extract Buildroot version from nerves_system_br, using default 2025.05")
        "2025.05"
    end
  end

  @doc """
  Validates that a defconfig exists for the given board.
  """
  def validate_board_defconfig(buildroot_path, board) do
    defconfig = Path.join([buildroot_path, "configs", "#{board}_defconfig"])

    unless File.exists?(defconfig) do
      Mix.raise("Could not find #{board}_defconfig in #{buildroot_path}/configs")
    end

    defconfig
  end
end
