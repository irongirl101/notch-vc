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

# Let user know
echo "Successfully built ${APP_BUNDLE}"
