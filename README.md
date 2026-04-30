
<p align="center">
  <img src="images/logo.png" width="32" style="vertical-align: middle; margin-right: 8px;">
  <span style="font-size: 32px; font-weight: bold; vertical-align: middle;">
    OpenVPN Auto Installer
  </span>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/Linux-FFCC33?style=for-the-badge&logo=linux&logoColor=white" alt="Linux">
  <img src="https://img.shields.io/badge/Debian-CE0058?style=for-the-badge&logo=debian&logoColor=white" alt="Debian">
  <img src="https://img.shields.io/badge/Ubuntu-E95420?style=for-the-badge&logo=ubuntu&logoColor=white" alt="Ubuntu">
  <br>
  <img src="https://img.shields.io/badge/Language-Bash-2563EB?style=for-the-badge&logo=gnu-bash&logoColor=white&labelColor=000F15&logoWidth=20" alt="Bash">
  <img src="https://img.shields.io/badge/License-MIT-2563EB?style=for-the-badge&logo=open-source-initiative&logoColor=white&labelColor=000F15&logoWidth=20" alt="License">
  <img src="https://img.shields.io/badge/Version-1.0.0-2563EB?style=for-the-badge&logo=semantic-release&logoColor=white&labelColor=000F15&logoWidth=20" alt="Version">
</p>

<p align="center">

  <a href="https://github.com/neikiri/openvpn-auto-installer/stargazers">
    <img src="https://img.shields.io/github/stars/neikiri/openvpn-auto-installer?style=social">
  </a>
  <a href="https://github.com/neikiri/openvpn-auto-installer/issues">
    <img src="https://img.shields.io/github/issues/neikiri/openvpn-auto-installer">
  </a>
  <img src="https://img.shields.io/badge/platform-Debian%20%7C%20Ubuntu-blue">
  <img src="https://img.shields.io/badge/OpenVPN-supported-green">
</p>

---

<p align="center">
  <img src="images/menu.png" alt="Menu" width="350"/>
</p>




## ✨ Features

* ⚙️ Install OpenVPN server
* ❌ Remove OpenVPN server
* 🔄 Reinstall OpenVPN server
* 🌐 Auto-detect public network interface
* 🌍 Auto-detect public IPv4
* 📄 Generate client `.ovpn` profile
* 🔥 Automatic NAT (iptables) configuration
* 🔁 Enable IP forwarding
* 🎨 Colored terminal menu
* 💾 Persistent firewall rules (iptables-save)
* ⚡ CLI arguments support (non-interactive mode)

---

## 🐧 Supported systems

* Debian 11 / 12
* Ubuntu 20.04 / 22.04 / 24.04

---

## 📦 Installation

```bash
git clone https://github.com/neikiri/openvpn-auto-installer.git
cd openvpn-auto-installer
chmod +x openvpn-installer.sh
sudo ./openvpn-installer.sh
```

---

## ⚡ CLI Usage (Non-interactive mode)

You can run the script without menu:

```bash
sudo ./openvpn-installer.sh install
sudo ./openvpn-installer.sh remove
sudo ./openvpn-installer.sh reinstall
```

Show help:

```bash
sudo ./openvpn-installer.sh --help
```
---

## 📁 Output

Client config will be created in the home directory of the user running `sudo`:

```bash
/home/username/client.ovpn
```

---

## ⚠️ Warning

This script modifies:

* OpenVPN configuration
* iptables firewall rules
* system networking settings

👉 Use it only on a VPS or server where you understand these changes.

---

## 📄 License

This project is licensed under the MIT License — see the [LICENSE](LICENSE) file for details.

---

## 👨‍💻 Author

**neikiri**
GitHub: https://github.com/neikiri

## 📬 Contact

- 📧 Email: dev@neiki.eu