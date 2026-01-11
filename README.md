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

### 1. Download
Download the `setup_mac.sh` script to your Mac.

### 2. Run the Script
Open your Terminal, navigate to the folder where you saved the script, and run the following commands:

```bash
# Make the script executable
chmod +x setup_mac.sh

# Run the setup wizard
./setup_mac.sh
```
### 3. Follow the Wizard
The script will check your system and guide you through the migration process interactively.

### 4. Finish
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

## License

MIT License.