#!/bin/bash

# Configuration
APP_NAME="Notch"
APP_BUNDLE="${APP_NAME}.app"
APP_MACOS_DIR="${APP_BUNDLE}/Contents/MacOS"
APP_RESOURCES_DIR="${APP_BUNDLE}/Contents/Resources"

# Clean previous build
rm -rf "${APP_BUNDLE}"

# Create directory structure
mkdir -p "${APP_MACOS_DIR}"
mkdir -p "${APP_RESOURCES_DIR}"

# Compile Swift code
swiftc -parse-as-library NotchApp.swift -o "${APP_MACOS_DIR}/NotchApp"

# Copy Info.plist
cp Info.plist "${APP_BUNDLE}/Contents/Info.plist"

# Add minimal PkgInfo (helps some launch/services tooling)
echo -n "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

# Ensure Resources isn't empty (some signing/assessment paths dislike it)
echo -n "" > "${APP_RESOURCES_DIR}/.placeholder"

# Remove any extended attributes before signing
xattr -cr "${APP_BUNDLE}" 2>/dev/null || true

# Ad-hoc sign to avoid Gatekeeper/LaunchServices issues
codesign --force --deep --sign - "${APP_BUNDLE}"

# Let user know
echo "Successfully built ${APP_BUNDLE}"
