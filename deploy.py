#!/usr/bin/env python3
import os
import sys
import shutil
import time
import subprocess
import requests

BOT_TOKEN = "8961965814:AAFBAC4G0e2eLFhBf3DRFgsvaQj4TDR3Gio"
CHAT_ID = "1433390895"

def log_info(msg):
    print(f"[\033[94mINFO\033[0m] {msg}", flush=True)

def log_verbose(msg):
    print(f"[\033[90mVERBOSE\033[0m] {msg}", flush=True)

def log_success(msg):
    print(f"[\033[92mSUCCESS\033[0m] {msg}", flush=True)

def log_error(msg):
    print(f"[\033[91mERROR\033[0m] {msg}", sys.stderr, flush=True)

def run_flutter_build():
    log_info("Starting Flutter build (split-per-abi release APK)...")
    start_time = time.time()
    
    cmd = ["flutter", "build", "apk", "--release", "--split-per-abi"]
    log_verbose(f"Command: {' '.join(cmd)}")
    
    try:
        # Launch subprocess and stream output live
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1
        )
        
        # Read stdout line-by-line in real time
        for line in process.stdout:
            print(f"  {line.strip()}", flush=True)
            
        process.wait()
        
        elapsed = time.time() - start_time
        if process.returncode != 0:
            raise subprocess.CalledProcessError(process.returncode, cmd)
            
        log_success(f"Flutter build completed in {elapsed:.2f} seconds.")
    except Exception as e:
        log_error(f"Flutter build failed: {e}")
        sys.exit(1)

def copy_apk():
    src = "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk"
    dst = "/Users/aswinharidas/Development/wayrouter-release.apk"
    
    log_info(f"Preparing to copy ARM64 APK...")
    log_verbose(f"Source: {src}")
    log_verbose(f"Destination: {dst}")
    
    if not os.path.exists(src):
        log_error(f"Source APK not found at: {src}")
        sys.exit(1)
        
    src_size = os.path.getsize(src)
    log_verbose(f"Source file size: {src_size / (1024 * 1024):.2f} MB")
    
    start_time = time.time()
    try:
        # Ensure destination directory exists
        dst_dir = os.path.dirname(dst)
        if not os.path.exists(dst_dir):
            log_verbose(f"Creating missing directory: {dst_dir}")
            os.makedirs(dst_dir, exist_ok=True)
            
        shutil.copy2(src, dst)
        elapsed = time.time() - start_time
        
        dst_size = os.path.getsize(dst)
        log_success(f"Copied APK to Development folder in {elapsed:.4f} seconds.")
        log_verbose(f"Destination file size: {dst_size / (1024 * 1024):.2f} MB")
        return dst
    except Exception as e:
        log_error(f"Failed to copy APK: {e}")
        sys.exit(1)

def send_via_telegram(file_path):
    url = f"https://api.telegram.org/bot{BOT_TOKEN}/sendDocument"
    log_info(f"Uploading APK via Telegram Bot API...")
    log_verbose(f"URL Target: {url}")
    log_verbose(f"Recipient Chat ID: {CHAT_ID}")
    
    if not os.path.exists(file_path):
        log_error(f"File not found for Telegram upload: {file_path}")
        sys.exit(1)
        
    file_size = os.path.getsize(file_path)
    log_verbose(f"Uploading file: {file_path} ({file_size / (1024 * 1024):.2f} MB)")
    
    start_time = time.time()
    try:
        with open(file_path, "rb") as f:
            files = {"document": f}
            data = {"chat_id": CHAT_ID}
            
            response = requests.post(url, data=data, files=files, timeout=60)
            
        elapsed = time.time() - start_time
        log_verbose(f"Telegram API Response HTTP Code: {response.status_code}")
        
        if response.status_code == 200:
            log_success(f"Telegram notification sent successfully in {elapsed:.2f} seconds!")
            log_verbose(f"Response data: {response.json()}")
        else:
            log_error(f"Failed to send via Telegram. Status Code: {response.status_code}")
            log_error(f"Response: {response.text}")
            sys.exit(1)
    except Exception as e:
        log_error(f"An error occurred while uploading to Telegram: {e}")
        sys.exit(1)

def main():
    total_start = time.time()
    log_info("=== Deployment Script Started ===")
    
    run_flutter_build()
    apk_path = copy_apk()
    send_via_telegram(apk_path)
    
    total_elapsed = time.time() - total_start
    log_success(f"=== Deployment Completed Successfully in {total_elapsed:.2f} seconds ===")

if __name__ == "__main__":
    main()
