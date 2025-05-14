# Nirmata Integration for Different Platforms

This folder contains three different Terraform configurations for integrating EKS with Nirmata:

## 1. nirmata-integrated.tf (Windows Version)

This configuration is optimized for Windows systems. It uses PowerShell commands to handle Windows path syntax and file iteration.

**Key Features:**
- PowerShell commands for file operations
- Windows-style path handling with backslashes
- Proper file iteration using PowerShell's `Get-ChildItem` and `foreach` loops
- `Start-Sleep` for waiting between steps

**When to Use:**
- When running Terraform on Windows machines

## 2. nirmata-integrated-linux.tf (Linux Version)

This configuration is optimized for Linux/Unix systems. It uses standard shell commands and Unix-style paths.

**Key Features:**
- Bash/shell commands for file operations
- Unix-style path handling with forward slashes
- Shell globbing with asterisks for file matching
- `sleep` command for waiting between steps

**When to Use:**
- When running Terraform on Linux, macOS, or other Unix-like systems

## 3. nirmata-integrated-cross-platform.tf (Universal Version)

This configuration automatically detects the operating system and uses the appropriate commands.

**Key Features:**
- Detects the OS automatically using Terraform's `pathexpand` function
- Uses conditional logic to select Windows or Linux operations
- Handles both Windows and Unix path formats
- Contains separate resources for each platform

**When to Use:**
- When your team uses a mix of operating systems
- When you're not sure which OS your client will use
- For maximum portability across environments

## How to Use

1. Choose the appropriate configuration file based on your platform:
   ```bash
   # For Windows
   cp nirmata-integrated.tf nirmata-integrated.tf.disabled
   cp nirmata-integrated-windows.tf.backup nirmata-integrated.tf

   # For Linux
   cp nirmata-integrated.tf nirmata-integrated.tf.disabled
   cp nirmata-integrated-linux.tf.backup nirmata-integrated.tf

   # For cross-platform support (default)
   # No action needed - this is the primary implementation
   ```

2. Run Terraform as normal:
   ```bash
   terraform init
   terraform apply
   ```

## Using Backup Files

We have created platform-specific backup files that can be used if needed:

1. **nirmata-integrated-windows.tf.backup** - Windows-specific version
2. **nirmata-integrated-linux.tf.backup** - Linux-specific version

To use a backup version:

1. First, rename or disable the current cross-platform file:
   ```bash
   mv nirmata-integrated.tf nirmata-integrated.tf.disabled
   ```

2. Then copy the desired backup file without the .backup extension:
   ```bash
   # For Windows-specific version:
   cp nirmata-integrated-windows.tf.backup nirmata-integrated.tf
   
   # OR for Linux-specific version:
   cp nirmata-integrated-linux.tf.backup nirmata-integrated.tf
   ```

3. Finally, run terraform apply:
   ```bash
   terraform apply
   ```

This allows you to easily switch between implementations if needed, though the cross-platform version should work well in most situations.

## How It Works

The cross-platform detection is done using this Terraform code:

```hcl
locals {
  is_windows = substr(pathexpand("~"), 0, 1) == "/" ? false : true
}
```

This checks if the home directory path starts with a forward slash (typical of Unix systems) or not (Windows).

Based on this detection, either the Windows-specific or Linux-specific resource is created (using the `count` parameter), and the appropriate commands are executed. 