defmodule NervesBootstrap.PlatformDetector do
  @moduledoc """
  Detects target platform configuration from Buildroot defconfig files,
  including architecture, DTB names, and platform-specific settings.
  """

  @doc """
  Infers the toolchain from a defconfig file path.
  """
  def infer_toolchain(defconfig_path) do
    defconfig_path
    |> File.read!()
    |> infer_toolchain_from_content()
  end

  @doc """
  Infers the toolchain from defconfig content.
  """
  def infer_toolchain_from_content(defconfig_content) do
    cond do
      defconfig_content =~ "BR2_aarch64=y" ->
        {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 14.2"}

      defconfig_content =~ "BR2_arm=y" and defconfig_content =~ "BR2_ARM_EABIHF=y" ->
        {:nerves_toolchain_armv7_nerves_linux_gnueabihf, "~> 14.2"}

      defconfig_content =~ "BR2_x86_64=y" ->
        {:nerves_toolchain_x86_64_nerves_linux_musl, "~> 14.2"}

      defconfig_content =~ "BR2_riscv=y" ->
        {:nerves_toolchain_riscv64_nerves_linux_gnu, "~> 14.2"}

      true ->
        {:nerves_toolchain_armv7_nerves_linux_gnueabihf, "~> 14.2"}
    end
  end

  @doc """
  Extracts the DTB (Device Tree Blob) name from defconfig content.
  """
  def extract_dtb_name(defconfig) do
    case Regex.run(~r/BR2_LINUX_KERNEL_INTREE_DTS_NAME="([^"]+)"/, defconfig) do
      [_, dtb_path] ->
        # Extract just the filename from the path and add .dtb extension
        dtb_path
        |> Path.basename()
        |> Kernel.<>(".dtb")
      _ -> nil
    end
  end

  @doc """
  Detects platform configuration from a defconfig file.
  """
  def detect_platform_config(defconfig_path) do
    defconfig = File.read!(defconfig_path)
    dtb_name = extract_dtb_name(defconfig)

    cond do
      # Raspberry Pi detection
      String.contains?(defconfig, "rpi") or String.contains?(defconfig, "BR2_PACKAGE_RPI") ->
        %{
          platform: :rpi,
          uboot_env_size: "0x20000",
          boot_part_offset: "8192",
          boot_part_count: "204800",
          rootfs_part_offset: "215040",
          fwup_ops: :rpi,
          boot_files: ["config.txt", "cmdline.txt", "start4.elf", "fixup4.dat"],
          kernel_name: "kernel8.img",
          dtb_name: dtb_name || "bcm2711-rpi-4-b.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 8192
        }

      # Allwinner/Sunxi detection
      String.contains?(defconfig, "sunxi") or
      String.contains?(defconfig, "BR2_TARGET_UBOOT_BOARD_DEFCONFIG=\"sun") or
      (dtb_name && String.starts_with?(dtb_name, "sun")) ->
        spl_config = if String.contains?(defconfig, "BR2_TARGET_UBOOT_SPL=y") do
          :sunxi_spl
        else
          :sunxi_standard
        end

        %{
          platform: spl_config,
          uboot_env_size: "0x20000",
          boot_part_offset: "2048",
          boot_part_count: "204800",
          rootfs_part_offset: "206848",
          fwup_ops: :sunxi,
          boot_files: ["u-boot-sunxi-with-spl.bin", "boot.scr"],
          kernel_name: "Image",
          dtb_name: dtb_name,
          needs_uboot_spl: true,
          uboot_spl_offset: "16",
          uboot_spl_count: "2032",
          uboot_env_count: "128",
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 8192
        }

      # x86_64 detection
      String.contains?(defconfig, "BR2_x86_64=y") ->
        %{
          platform: :x86_64,
          uboot_env_size: "0x20000",
          boot_part_offset: "2048",
          boot_part_count: "204800",
          rootfs_part_offset: "206848",
          fwup_ops: :x86_64,
          boot_files: ["bzImage", "grub.cfg"],
          kernel_name: "bzImage",
          dtb_name: nil,  # x86_64 n'utilise pas de DTB
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 8192
        }

      # RISC-V detection
      String.contains?(defconfig, "BR2_riscv=y") ->
        %{
          platform: :riscv64,
          uboot_env_size: "0x20000",
          boot_part_offset: "2048",
          boot_part_count: "204800",
          rootfs_part_offset: "206848",
          fwup_ops: :riscv64,
          boot_files: ["u-boot.bin", "boot.scr"],
          kernel_name: "Image",
          dtb_name: dtb_name || "generic-riscv64.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: false,  # RISC-V n'a pas de partition boot
          uboot_offset: 16,
          uboot_env_offset: 8192
        }

      # Generic ARM detection
      String.contains?(defconfig, "BR2_arm=y") ->
        %{
          platform: :generic_arm,
          uboot_env_size: "0x20000",
          boot_part_offset: "2048",
          boot_part_count: "204800",
          rootfs_part_offset: "206848",
          fwup_ops: :generic,
          boot_files: ["u-boot.bin", "MLO", "boot.scr"],
          kernel_name: "zImage",
          dtb_name: dtb_name || "generic-arm.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 8192
        }

      # Generic ARM64 detection
      String.contains?(defconfig, "BR2_aarch64=y") ->
        %{
          platform: :generic_arm64,
          uboot_env_size: "0x20000",
          boot_part_offset: "2048",
          boot_part_count: "204800",
          rootfs_part_offset: "206848",
          fwup_ops: :generic,
          boot_files: ["u-boot.bin", "boot.scr"],
          kernel_name: "Image",
          dtb_name: dtb_name || "generic-arm64.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 8192
        }

      # Default fallback
      true ->
        %{
          platform: :generic_arm,
          uboot_env_size: "0x20000",
          boot_part_offset: "2048",
          boot_part_count: "204800",
          rootfs_part_offset: "206848",
          fwup_ops: :generic,
          boot_files: ["u-boot.bin", "MLO", "boot.scr"],
          kernel_name: "zImage",
          dtb_name: dtb_name || "generic-arm.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 8192
        }
    end
  end

  @doc """
  Gets architecture configuration for toolchain generation.
  """
  def get_arch_config({toolchain_name, _version}) do
    case toolchain_name do
      :nerves_toolchain_aarch64_nerves_linux_gnu ->
        %{arch: "aarch64", abi: "gnu", target_cpu: "cortex-a53"}

      :nerves_toolchain_armv7_nerves_linux_gnueabihf ->
        %{arch: "arm", abi: "gnueabihf", target_cpu: "cortex-a7"}

      :nerves_toolchain_x86_64_nerves_linux_musl ->
        %{arch: "x86_64", abi: "musl", target_cpu: "x86_64"}

      :nerves_toolchain_riscv64_nerves_linux_gnu ->
        %{arch: "riscv64", abi: "gnu", target_cpu: "riscv64"}

      _ ->
        %{arch: "arm", abi: "gnueabihf", target_cpu: "cortex-a7"}
    end
  end
end
