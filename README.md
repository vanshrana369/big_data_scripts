# Big Data Scripts (Windows)

PowerShell scripts to **install and configure Apache Hadoop, HBase, and Hive on Windows** with minimal manual steps. This repository is focused on repeatable, automated setup for local single‑node development and testing environments.

## What’s Included

| Script | Purpose |
| --- | --- |
| `install-hadoop.ps1` | Automated Hadoop install and configuration on Windows |
| `fix-hadoop.ps1` | Repairs common Hadoop setup issues (paths, configs) |
| `fix-hadoop-permissions.ps1` | Fixes permissions for Hadoop directories |
| `install-hbase.ps1` | Automated HBase install and integration with Hadoop |
| `install-hive.ps1` | Automated Hive install and basic configuration |

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Administrator privileges
- Internet connection (for downloading binaries)

## Quick Start

1. **Open PowerShell as Administrator**
2. Run the installer you need:

```powershell
# Hadoop
Set-ExecutionPolicy Bypass -Scope Process -Force; .\install-hadoop.ps1

# HBase
Set-ExecutionPolicy Bypass -Scope Process -Force; .\install-hbase.ps1

# Hive
Set-ExecutionPolicy Bypass -Scope Process -Force; .\install-hive.ps1
```

> Tip: If you only need to repair an existing Hadoop setup, use `fix-hadoop.ps1` or `fix-hadoop-permissions.ps1` instead of reinstalling.

## Typical Flow

1. Install **Hadoop**
2. Install **HBase** (uses Hadoop)
3. Install **Hive** (uses Hadoop)

## After Installation (Hadoop)

```cmd
C:\hadoop\sbin\start-dfs.cmd
C:\hadoop\sbin\start-yarn.cmd
jps
```

Expected `jps` output includes:

- `NameNode`
- `DataNode`
- `ResourceManager`
- `NodeManager`

## Troubleshooting

- **Scripts won’t run**
  ```powershell
  Set-ExecutionPolicy Bypass -Scope Process -Force
  ```

- **Hadoop or Java not found**
  Open a **new** terminal window and re-check `JAVA_HOME`, `HADOOP_HOME`.

- **Permission errors**
  Run:
  ```powershell
  .\fix-hadoop-permissions.ps1
  ```

## Notes

- These scripts are intended for **local development/single-node setups**.
- Always review scripts before running in production or on shared machines.

## Contributing

PRs and issues are welcome. If you test on a new Windows version or hit a bug, please open an issue with logs and steps to reproduce.

## Author

**Vansh Rana** — GitHub: [@vanshrana369](https://github.com/vanshrana369)
