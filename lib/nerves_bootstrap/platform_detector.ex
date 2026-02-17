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

      _ ->
        nil
    end
  end

  @doc """
  Detects platform configuration from a defconfig file.
  """
  def detect_platform_config(defconfig_path) do
    defconfig = File.read!(defconfig_path)
    dtb_name = extract_dtb_name(defconfig)

    cond do
      # Raspberry Pi detection (more specific to avoid false positives)
      (String.contains?(defconfig, "rpi") and not String.contains?(defconfig, "rpiv2")) or
        String.contains?(defconfig, "BR2_PACKAGE_RPI") or
        String.contains?(defconfig, "bcm27") or
          String.contains?(defconfig, "raspberrypi") ->
        %{
          platform: :rpi,
          uboot_env_size: "0x20000",
          fwup_ops: :rpi,
          boot_files: ["config.txt", "cmdline.txt", "start4.elf", "fixup4.dat"],
          kernel_name: "kernel8.img",
          dtb_name: dtb_name || "bcm2711-rpi-4-b.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 16,
          dev_path: "/dev/mmcblk0",
          boot_dev_path: "/dev/mmcblk0p1",
          app_dev_path: "/dev/mmcblk0p3"
        }

      # Allwinner/Sunxi detection
      String.contains?(defconfig, "sunxi") or
        String.contains?(defconfig, "BR2_TARGET_UBOOT_BOARD_DEFCONFIG=\"sun") or
          (dtb_name && String.starts_with?(dtb_name, "sun")) ->
        spl_config =
          if String.contains?(defconfig, "BR2_TARGET_UBOOT_SPL=y") do
            :sunxi_spl
          else
            :sunxi_standard
          end

        %{
          platform: spl_config,
          uboot_env_size: "0x20000",
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
          uboot_env_offset: 16,
          dev_path: "/dev/mmcblk0",
          boot_dev_path: "/dev/mmcblk0p1",
          app_dev_path: "/dev/mmcblk0p3"
        }

      # x86_64 detection
      String.contains?(defconfig, "BR2_x86_64=y") ->
        %{
          platform: :x86_64,
          uboot_env_size: "0x20000",
          fwup_ops: :x86_64,
          boot_files: ["bzImage"],
          kernel_name: "bzImage",
          dtb_name: nil,
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 16,
          dev_path: "/dev/sda",
          boot_dev_path: "/dev/sda1",
          app_dev_path: "/dev/sda3"
        }

      # RISC-V detection
      String.contains?(defconfig, "BR2_riscv=y") ->
        %{
          platform: :riscv64,
          uboot_env_size: "0x20000",
          fwup_ops: :riscv64,
          boot_files: [],
          kernel_name: "Image",
          dtb_name: dtb_name || "generic-riscv64.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: false,
          uboot_offset: 16,
          uboot_env_offset: 8192,
          dev_path: "/dev/mmcblk0",
          boot_dev_path: nil,
          app_dev_path: "/dev/mmcblk0p2"
        }

      # Generic ARM detection
      String.contains?(defconfig, "BR2_arm=y") ->
        %{
          platform: :generic_arm,
          uboot_env_size: "0x20000",
          fwup_ops: :generic,
          boot_files: ["u-boot.bin", "MLO", "boot.scr"],
          kernel_name: "zImage",
          dtb_name: dtb_name || "generic-arm.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 16,
          dev_path: "/dev/mmcblk0",
          boot_dev_path: "/dev/mmcblk0p1",
          app_dev_path: "/dev/mmcblk0p3"
        }

      # Generic ARM64 detection
      String.contains?(defconfig, "BR2_aarch64=y") ->
        %{
          platform: :generic_arm64,
          uboot_env_size: "0x20000",
          fwup_ops: :generic,
          boot_files: ["u-boot.bin", "boot.scr"],
          kernel_name: "Image",
          dtb_name: dtb_name || "generic-arm64.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 16,
          dev_path: "/dev/mmcblk0",
          boot_dev_path: "/dev/mmcblk0p1",
          app_dev_path: "/dev/mmcblk0p3"
        }

      # Default fallback
      true ->
        %{
          platform: :generic_arm,
          uboot_env_size: "0x20000",
          fwup_ops: :generic,
          boot_files: ["u-boot.bin", "MLO", "boot.scr"],
          kernel_name: "zImage",
          dtb_name: dtb_name || "generic-arm.dtb",
          needs_uboot_spl: false,
          needs_boot_partition: true,
          uboot_offset: 16,
          uboot_env_offset: 16,
          dev_path: "/dev/mmcblk0",
          boot_dev_path: "/dev/mmcblk0p1",
          app_dev_path: "/dev/mmcblk0p3"
        }
    end
  end

  @doc """
  Estimates the boot partition size in 512-byte blocks based on what the
  platform needs to store in the boot partition.

  The boot partition holds the kernel, DTBs, DTSOs, boot scripts, and
  platform-specific firmware files. The estimate includes a 2x safety
  margin to accommodate kernel growth and future additions.

  Returns the block count as an integer.
  """
  def estimate_boot_partition_blocks(platform_config) do
    if Map.get(platform_config, :needs_boot_partition, true) do
      # Estimate sizes in bytes for what goes in the boot partition
      kernel_estimate = estimate_kernel_size(platform_config)
      dtb_estimate = if platform_config.dtb_name, do: 256 * 1024, else: 0
      boot_script_estimate = 16 * 1024

      platform_files_estimate =
        case platform_config.platform do
          :rpi ->
            # start4.elf (~5.3 MiB) + fixup4.dat (~30 KB) + config.txt + cmdline.txt
            6 * 1024 * 1024

          :x86_64 ->
            # EFI bootloader
            2 * 1024 * 1024

          :sunxi_spl ->
            # U-Boot SPL is written raw, not to boot partition
            0

          :sunxi_standard ->
            # U-Boot binary stored in boot partition
            1 * 1024 * 1024

          _ ->
            # Generic U-Boot + MLO
            1 * 1024 * 1024
        end

      total_bytes =
        kernel_estimate + dtb_estimate + boot_script_estimate + platform_files_estimate

      # Apply 2x safety margin, round up to MiB boundary, convert to 512-byte blocks
      total_with_margin = total_bytes * 2
      mib = div(total_with_margin + 1024 * 1024 - 1, 1024 * 1024)
      # Minimum 24 MiB for boot partition
      mib = max(mib, 24)
      # Convert MiB to 512-byte blocks
      mib * 2048
    else
      0
    end
  end

  # Estimate uncompressed kernel image size based on architecture.
  # ARM zImage is compressed (~5-8 MiB), ARM64/RISC-V Image is uncompressed (~15-25 MiB),
  # x86_64 bzImage is compressed (~8-12 MiB).
  defp estimate_kernel_size(platform_config) do
    case platform_config.kernel_name do
      "zImage" -> 8 * 1024 * 1024
      "bzImage" -> 12 * 1024 * 1024
      "Image" -> 25 * 1024 * 1024
      "kernel8.img" -> 25 * 1024 * 1024
      _ -> 15 * 1024 * 1024
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
