<div align="center">

# Big Data Scripts for Windows

**Automated PowerShell installers for Apache Hadoop, HBase, and Hive on Windows — minimal manual setup, repeatable results.**

[![Stars](https://img.shields.io/github/stars/vanshrana369/big_data_scripts?style=for-the-badge&color=yellow)](https://github.com/vanshrana369/big_data_scripts/stargazers)
[![Forks](https://img.shields.io/github/forks/vanshrana369/big_data_scripts?style=for-the-badge&color=blue)](https://github.com/vanshrana369/big_data_scripts/network/members)
[![License](https://img.shields.io/github/license/vanshrana369/big_data_scripts?style=for-the-badge)](LICENSE)
[![PowerShell](https://img.shields.io/badge/PowerShell-5.1+-5391FE?style=for-the-badge&logo=powershell&logoColor=white)](https://github.com/PowerShell/PowerShell)
[![Windows](https://img.shields.io/badge/Windows-10%2F11-0078D6?style=for-the-badge&logo=windows&logoColor=white)](https://www.microsoft.com/windows)

</div>

---

## Overview

This repo provides **Windows‑friendly automation** for setting up a local big‑data stack. It currently includes:

- **Hadoop** (HDFS + YARN) single‑node install
- **HBase** install and integration with Hadoop
- **Hive** install and basic configuration on Hadoop

---

## Scripts

| Script | What it does |
| --- | --- |
| `install-hadoop.ps1` | Installs and configures Hadoop on Windows |
| `fix-hadoop.ps1` | Repairs common Hadoop setup issues |
| `fix-hadoop-permissions.ps1` | Fixes permissions for Hadoop directories |
| `install-hbase.ps1` | Installs HBase and configures it to use Hadoop |
| `install-hive.ps1` | Installs Hive and configures it for Hadoop |

---

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Administrator privileges
- Internet connection (downloads binaries)

---

## Quick Start

> **Open PowerShell as Administrator**

```powershell
# Hadoop
Set-ExecutionPolicy Bypass -Scope Process -Force; .\install-hadoop.ps1

# HBase (requires Hadoop)
Set-ExecutionPolicy Bypass -Scope Process -Force; .\install-hbase.ps1

# Hive (requires Hadoop)
Set-ExecutionPolicy Bypass -Scope Process -Force; .\install-hive.ps1
```

**Repair-only scripts** (if you already have Hadoop installed):

```powershell
.\fix-hadoop.ps1
.\fix-hadoop-permissions.ps1
```

---

## Typical Flow

1. Install **Hadoop**
2. Install **HBase** (uses Hadoop)
3. Install **Hive** (uses Hadoop)

---

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

---

## Troubleshooting

- **Scripts won’t run**
  ```powershell
  Set-ExecutionPolicy Bypass -Scope Process -Force
  ```

- **Hadoop or Java not found**
  Open a **new** terminal window and re-check `JAVA_HOME`, `HADOOP_HOME`.

- **Permission errors**
  ```powershell
  .\fix-hadoop-permissions.ps1
  ```

---

## Notes

- These scripts are intended for **local development/single‑node setups**.
- Review scripts before running in production or on shared machines.

---

## Contributing

PRs and issues are welcome. If you test on a new Windows version or hit a bug, please open an issue with logs and steps to reproduce.

---

## Author

**Vansh Rana** — GitHub: [@vanshrana369](https://github.com/vanshrana369)
