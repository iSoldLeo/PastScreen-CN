#!/bin/bash
# Clean all PastScreen installations and preferences before testing
# Usage: ./scripts/clean_install.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}======================================${NC}"
echo -e "${BLUE}PastScreen Clean Install Script${NC}"
echo -e "${BLUE}======================================${NC}"
echo ""

# Confirmation
echo -e "${YELLOW}This will remove ALL PastScreen data:${NC}"
echo "  • Application from /Applications"
echo "  • All preferences and settings"
echo "  • Security-scoped bookmarks"
echo "  • Launch agents"
echo "  • Caches and temporary files"
echo ""
read -p "Continue? (y/n) " -n 1 -r
echo ""
if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo -e "${RED}Cancelled.${NC}"
    exit 1
fi

echo ""
echo -e "${BLUE}Step 1: Stopping PastScreen if running...${NC}"
pkill -x "PastScreen" 2>/dev/null || echo "  (not running)"
sleep 1

echo ""
echo -e "${BLUE}Step 2: Removing application...${NC}"
if [ -d "/Applications/PastScreen.app" ]; then
    rm -rf "/Applications/PastScreen.app"
    echo -e "  ${GREEN}✓${NC} Removed /Applications/PastScreen.app"
else
    echo "  (not found in /Applications)"
fi

echo ""
echo -e "${BLUE}Step 3: Removing preferences...${NC}"
PREFS_FILE="$HOME/Library/Preferences/com.ecologni.PastScreen.plist"
if [ -f "$PREFS_FILE" ]; then
    rm "$PREFS_FILE"
    echo -e "  ${GREEN}✓${NC} Removed preferences"
else
    echo "  (no preferences found)"
fi

# Also clear defaults cache
defaults delete com.ecologni.PastScreen 2>/dev/null && echo -e "  ${GREEN}✓${NC} Cleared UserDefaults cache" || echo "  (no cached defaults)"

echo ""
echo -e "${BLUE}Step 4: Removing security-scoped bookmarks...${NC}"
BOOKMARKS_DIR="$HOME/Library/Application Support/com.ecologni.PastScreen"
if [ -d "$BOOKMARKS_DIR" ]; then
    rm -rf "$BOOKMARKS_DIR"
    echo -e "  ${GREEN}✓${NC} Removed bookmarks"
else
    echo "  (no bookmarks found)"
fi

echo ""
echo -e "${BLUE}Step 5: Removing launch agents...${NC}"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.ecologni.PastScreen.plist"
if [ -f "$LAUNCH_AGENT" ]; then
    launchctl unload "$LAUNCH_AGENT" 2>/dev/null || true
    rm "$LAUNCH_AGENT"
    echo -e "  ${GREEN}✓${NC} Removed launch agent"
else
    echo "  (no launch agent found)"
fi

echo ""
echo -e "${BLUE}Step 6: Removing caches...${NC}"
CACHE_DIR="$HOME/Library/Caches/com.ecologni.PastScreen"
if [ -d "$CACHE_DIR" ]; then
    rm -rf "$CACHE_DIR"
    echo -e "  ${GREEN}✓${NC} Removed caches"
else
    echo "  (no caches found)"
fi

echo ""
echo -e "${BLUE}Step 7: Removing logs...${NC}"
LOG_DIR="$HOME/Library/Logs/PastScreen"
if [ -d "$LOG_DIR" ]; then
    rm -rf "$LOG_DIR"
    echo -e "  ${GREEN}✓${NC} Removed logs"
else
    echo "  (no logs found)"
fi

echo ""
echo -e "${BLUE}Step 8: Removing Containers (if any)...${NC}"
CONTAINER_DIR="$HOME/Library/Containers/com.ecologni.PastScreen"
if [ -d "$CONTAINER_DIR" ]; then
    rm -rf "$CONTAINER_DIR"
    echo -e "  ${GREEN}✓${NC} Removed container"
else
    echo "  (no container found)"
fi

echo ""
echo -e "${BLUE}Step 9: Clearing screenshot folder (optional)...${NC}"
echo -e "${YELLOW}Do you want to clear existing screenshots?${NC}"
read -p "Clear screenshots? (y/n) " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    read -p "Enter screenshot folder path (e.g., ~/Pictures/Screenshots): " SCREENSHOT_PATH
    if [ -d "$SCREENSHOT_PATH" ]; then
        SCREENSHOT_COUNT=$(find "$SCREENSHOT_PATH" -name "Screenshot-*.png" -o -name "Screenshot-*.jpg" 2>/dev/null | wc -l | xargs)
        if [ "$SCREENSHOT_COUNT" -gt 0 ]; then
            find "$SCREENSHOT_PATH" -name "Screenshot-*.png" -delete 2>/dev/null || true
            find "$SCREENSHOT_PATH" -name "Screenshot-*.jpg" -delete 2>/dev/null || true
            echo -e "  ${GREEN}✓${NC} Deleted $SCREENSHOT_COUNT screenshots"
        else
            echo "  (no screenshots found)"
        fi
    else
        echo "  (folder not found)"
    fi
else
    echo "  (skipped)"
fi

echo ""
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}✅ PastScreen completely removed!${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo "You can now:"
echo "  1. Build & Run (⌘R) in Xcode for a clean test"
echo "  2. Or install a fresh .app bundle"
echo ""
