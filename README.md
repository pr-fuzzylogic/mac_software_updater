![License](https://img.shields.io/github/license/pr-fuzzylogic/mac_software_updater?color=blue)
![Last Commit](https://img.shields.io/github/last-commit/pr-fuzzylogic/mac_software_updater)
![Repo Size](https://img.shields.io/github/repo-size/pr-fuzzylogic/mac_software_updater)
# macOS Maintenance & Migration Toolkit 

A powerful automation tool designed to audit, migrate, and maintain your macOS applications. This project combines **Homebrew**, **Mac App Store CLI (mas)**, and **SwiftBar** to create a unified system for keeping your software clean and up-to-date.

## 🚀 What It Does

### 1. Automated Setup & Migration (`setup_mac.sh`)
An interactive wizard that scans your system and organizes your applications.
* **Environment Setup:** Automatically installs missing tools: `Homebrew`, `mas`, `sf-symbols`, and `SwiftBar`.
* **Smart Audit:** Scans your `/Applications` folder to detect how apps were installed (App Store vs. Homebrew vs. Manual Drag & Drop).
* **Migration Wizard:** Asks you what to do with unmanaged apps:
    * **[A]pp Store:** Replaces the manual version with the official App Store version.
    * **[B]rew:** Replaces the manual version with a Homebrew Cask (preserving settings).
    * **[L]eave:** Keeps the app as it is.
* **Auto-Config:** Automatically installs and configures the update monitor plugin.

### 2. Menu Bar Monitor (`update_system.1h.sh`)
A seamless plugin for **SwiftBar** that sits in your macOS Menu Bar.
* **Live Status:** Shows a cycle icon with the count of available updates (combining Homebrew & App Store).
* **One-Click Update:** Clicking "Update All" launches a terminal process that updates everything, cleans up system garbage, and refreshes the status automatically.

---

## 📋 Prerequisites

* **macOS** (Intel or Apple Silicon).
* **Internet Connection**.
* No prior installation of Homebrew is required – the script handles everything.

---

## 🛠 Quick Start Guide

### 1. Run the Script
The easiest way to get started is to run this command directly in your Terminal. It will download and launch the installer in one go:

```bash
/bin/zsh -c "$(curl -fsSL https://raw.githubusercontent.com/pr-fuzzylogic/mac_software_updater/main/setup_mac.sh)"
```
### 2. Follow the Wizard
The script will check your system and guide you through the migration process interactively.

### 3. Finish
Once finished, **SwiftBar** will launch automatically.

> **Important:** If macOS asks for permission to access your Documents folder, click **Allow**. This is required for the update plugin to work.

---

## 🧠 How It Works

This toolkit uses **"Atomic Detection"** logic to ensure 100% accuracy:

* **Homebrew Apps:** Identified by checking if the application file is a **symlink** pointing to the internal Caskroom.
* **App Store Apps:** Identified by verifying the presence of a valid `_MASReceipt` inside the application bundle.
* **Manual Apps:** Anything else is flagged for your review.

## ⚠️ Notes

* **System Apps:** Apple system applications (Safari, Photos, etc.) are automatically ignored to prevent errors.
* **Complex Software:** Large suites like Adobe CC or Microsoft Office are best left as `[L]eave` unless you specifically want to reinstall them via Homebrew.

## 📦 Tools Used in This Toolkit

To provide a seamless experience, this project integrates several industry-standard tools for macOS power users:

* **[Homebrew](https://brew.sh)**
    The essential package manager for macOS. I use it to install, update, and manage command-line tools and desktop applications (Casks) that Apple does not include by default.
* **[mas-cli](https://github.com/mas-cli/mas)**
    A command-line interface for the Mac App Store. I implement this to automate updates for your App Store apps without needing to open the graphical interface.
* **[SwiftBar](https://swiftbar.app)**
    A powerful tool that lets you customize your macOS menu bar using scripts. It serves as the frontend for my real-time update monitor.
* **[SF Symbols](https://developer.apple.com/sf-symbols/)**
    A library of iconography designed by Apple. I use these symbols to provide native-looking icons in your menu bar. 
    **Note:** This is optional; you only need it if you want to browse and change icons manually. The script works perfectly with the built-in defaults.

---

### 🎨 How to Customize Icons
If you want to change the icons displayed in your menu bar, follow these steps:
1. Open the **SF Symbols** app to find a symbol you like (e.g., `gear`, `bolt.fill`).
2. Right-click the symbol and select **Copy Name**.
3. Open `update_system.1h.sh` in a text editor.
4. Find the line starting with `echo "$total | sfimage=..."`.
5. Replace the value after `sfimage=` with your copied name.
6. Save the file and SwiftBar will update automatically.

## License

MIT License.