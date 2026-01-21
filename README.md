## Usage

FastDL is a PowerShell-based script and works the same across platforms once PowerShell is available.

---

### Windows

**Requirements**

* Windows 10/11
* PowerShell 5.1 or later (PowerShell 7+ recommended)

**Run**

```powershell
irm https://raw.githubusercontent.com/rinkanekoii/fastdl/v1.0.0/fastdl.ps1 | iex
```

---

### macOS

**Requirements**

* PowerShell 7+
* aria2 (installed automatically if missing)

**Install PowerShell**

```bash
brew install --cask powershell
```

**Run**

```bash
pwsh -Command "irm https://raw.githubusercontent.com/rinkanekoii/fastdl/v1.0.0/fastdl.ps1 | iex"
```

---

### Linux

**Requirements**

* PowerShell 7+
* curl / wget available

**Install PowerShell (example: Ubuntu)**

```bash
sudo apt install -y powershell
```

**Run**

```bash
pwsh -Command "irm https://raw.githubusercontent.com/rinkanekoii/fastdl/v1.0.0/fastdl.ps1 | iex"
```

---

### Notes

* `irm` and `iex` are PowerShell commands and must be run inside PowerShell (`pwsh`).
* The script does not require administrator/root privileges.
* Source code can be reviewed safely before execution:

[https://raw.githubusercontent.com/rinkanekoii/fastdl/v1.0.0/fastdl.ps1](https://raw.githubusercontent.com/rinkanekoii/fastdl/v1.0.0/fastdl.ps1)
