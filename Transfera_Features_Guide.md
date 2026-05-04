# Transfera: Architecture & Feature Guide

Transfera is a high-speed, indestructible cross-platform file transfer application built with Flutter. It specializes in establishing seamless connections between desktop hosts (macOS) and mobile devices (Android) using a deeply resilient, multi-transport network architecture.

---

## 1. Hybrid Networking Architecture

Transfera doesn't rely on a single point of failure. It utilizes a "Smart Race" system to dynamically route your file through the fastest available tunnel.

*   **Encrypted P2P (WebRTC DataChannels)**: The primary, high-speed route. It negotiates a direct connection between devices, bypassing cloud servers entirely for massive throughput.
*   **Cloudflare Socket Relay**: A highly reliable HTTP fallback mechanism. If NAT firewalls or strict mobile networks block P2P, the data routes through a secure Cloudflare tunnel using Socket.IO.
*   **Local TCP**: Automatically activates if both devices are confirmed to be on the exact same local Wi-Fi network, providing gigabit local speeds without internet usage.

## 2. Indestructible Resumption Engine

The crown jewel of Transfera is its ability to survive catastrophic network failures.

*   **Byte-Accurate Offset Resumption**: If you switch from Wi-Fi to a 4G hotspot mid-transfer, the connection will drop. When the Android device reconnects, it sends a `resume_request` containing the exact byte size of the file currently saved on disk. The Mac instantly rewinds its stream and resumes uploading from that precise byte, ensuring 0 corrupted data and no wasted progress.
*   **Warm Fallbacks**: If WebRTC drops unexpectedly, the stream seamlessly locks to the Relay socket without restarting the transfer or dropping a single chunk.

## 3. Transport Optimization Suite (Smart Configs)

The `config.dart` file houses a suite of advanced routing and throughput optimizations:

*   **Smart Transport Race (`smartTransportRace`)**: Simultaneously opens WebRTC and Relay connections and locks onto whichever completes the handshake first.
*   **Carrier Learning (`carrierLearning`)**: Remembers historical success rates across different cellular carriers. If WebRTC traditionally fails on "Jio 4G", it will skip the race and instantly connect via Relay.
*   **Smart Switching (`smartSwitching`)**: Actively monitors upload throughput every 3 seconds. If the network degrades severely (e.g., drops below 100 KB/s for 6 seconds), it seamlessly switches the route mid-transfer without resetting progress.

## 4. High-Performance File Handling

*   **Adaptive Chunk Size (`adaptiveChunkSize`)**: Instead of reading the file blindly, Transfera reads in chunks. If the network is stable, the chunk size dynamically scales up from `512KB` to `2MB` to eliminate overhead.
*   **Encrypt-Ahead Buffer (`parallelChunks`)**: Safely pre-reads and encrypts the *next* chunk in the background while the *current* chunk is busy traveling through the network, virtually eliminating CPU idle time.
*   **Strict Sequential ACKs**: Both WebRTC and the Relay strictly await chunk delivery (or monitor buffer backpressure) before proceeding, ensuring the Android receiver is never overwhelmed with out-of-order packets.

## 5. Security

*   **AES-CTR Streaming Encryption**: Every byte transferred over the network is heavily encrypted. 
*   **Offset-based IV Generation**: The AES Initialization Vector (IV) is dynamically calculated based on the file's absolute byte offset. This ensures that even if a transfer is paused and resumed hours later, the encryption math perfectly aligns with the exact byte being sent.

## 6. Native Android Integration

*   **Gallery Auto-Save**: Once a transfer completes, the Android native file handler (`file_handler_native.dart`) analyzes the file extension. If it detects an image or video (`.mp4`, `.png`, `.heic`), it automatically invokes `image_gallery_saver` to push the file directly into the user's Photos app, bypassing hidden storage folders.
*   **Permission Management**: Automatically negotiates Android 13+ granular media permissions upon opening the app.

## 7. Advanced Telemetry & UI

*   **Real-time Metrics**: Terminal logs actively report throughput speeds (`KB/s`), retries, and buffer backpressure events.
*   **Dynamic Route Indicator**: The UI badge updates live mid-transfer to show exactly which transport layer (WebRTC, Relay, or TCP) is currently moving the bytes.
