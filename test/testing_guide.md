# 🚀 Transfera Test Drive Guide

Follow these steps to perform your first secure file transfer using Transfera.

## Step 1: Start the Signaling Server (Mac)
The app needs a "meeting point" to find other devices. Let's start the server on your Mac.

1. Open a **new terminal** window.
2. Run these commands:
   ```bash
   cd /Users/suvodeepchowdhury/Transfera/server
   npm install        # Only needed the first time
   node index.js
   ```
   > [!NOTE]
   > The server is now listening at `ws://192.0.0.2:3000`. Keep this window open!

## Step 2: Initialize your Environment (Mac)
Since I installed Flutter and Java locally for you, you need to tell your terminal where they are.

1. In another terminal window, run:
   ```bash
   cd /Users/suvodeepchowdhury/Transfera
   source ./start_dev.sh
   ```
   > [!TIP]
   > You should now see a "✅ Transfera Environment Initialized!" message. You can now run `flutter` commands.

## Step 3: Launch the App

### On your Mac (Sender)
1. In the terminal you initialized in Step 2, run:
   ```bash
   cd app
   flutter run -d macos
   ```
2. Once the app opens, click **"Send File"** and pick any file (e.g., a photo or document).
3. A QR code will appear.

### On your Android (Receiver)
1. Transfer the file `/Users/suvodeepchowdhury/Transfera/test/transfera-release.apk` to your phone.
2. Install and open the **Transfera** app.
3. Tap **"Receive File"**.
4. Scan the QR code displayed on your Mac screen.

## Step 4: Watch the Transfer!
- As soon as the QR is scanned, the devices will perform a secure P2P handshake.
- You will see a progress bar on both devices.
- Once finished, the file will be in your Android phone's **Downloads** folder.

---

> [!IMPORTANT]
> **Production Note:** For testing with friends outside your WiFi, you will need to deploy the `server/` code to a public VPS (like AWS or DigitalOcean) and update the `signalingUrl` to your public IP.
