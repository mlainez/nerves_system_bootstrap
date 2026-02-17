# Nerves System Bootstrap

This project adds a `mix nerves.system.bootstrap` task that generates
a minimal Nerves system from an existing Buildroot board defconfig.

## Usage

Clone this repo and install dependencies:

```bash
mix deps.get


Usage: mix nerves.system.bootstrap <board> [options]

Options:
  --buildroot PATH            Path to a local Buildroot source tree
  --buildroot-url URL         Git URL of a Buildroot repository (or fork)
  --buildroot-branch BRANCH   Branch/tag to check out
  --buildroot-external PATH   Path to a Buildroot external tree
```
