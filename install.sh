
#!/data/data/com.termux/files/usr/bin/bash

# IP INFORMATION GATHERING
# Developer: UG ALOK

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}================================${NC}"
echo -e "${GREEN}   IP INFORMATION GATHERING${NC}"
echo -e "${GREEN}   Developer: UG ALOK${NC}"
echo -e "${GREEN}================================${NC}"

echo -e "${YELLOW}[1] Checking Python...${NC}"
if ! command -v python >/dev/null 2>&1; then
    echo "Python not found. Installing..."
    pkg install python -y || exit 1
fi

echo -e "${YELLOW}[2] Installing requests...${NC}"
python -m pip install requests || exit 1

echo -e "${YELLOW}[3] Checking main file...${NC}"
if [ ! -f "IP info.sh" ]; then
    echo "Error: IP info.sh not found!"
    exit 1
fi

echo -e "${GREEN}Installation completed!${NC}"
echo
echo "Starting IP Information Gathering..."
python "IP info.sh" 
