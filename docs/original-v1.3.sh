#!/bin/bash

# RMA GPU Log Collection Script
# This script collects logs and runs tests for AMD and Nvidia GPUs for RMA purposes

# Check if running root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

# Get current username
if [ -n "$SUDO_USER" ]; then
  CURRENT_USER=$SUDO_USER
else
  CURRENT_USER=$(whoami)
fi

# Date and time for folder name
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")

# Validate input against a list of options
validate_input() {
  local input=$1
  shift
  local options=("$@")
  
  for option in "${options[@]}"; do
    if [[ "${option,,}" == "${input,,}" ]]; then
      echo "${option}"
      return 0
    fi
  done
  
  echo "Invalid input. Please choose from the available options." >&2
  return 1
}

# Function to collect system logs
collect_system_logs() {
  local log_dir=$1
  
  echo "Collecting system logs..."
  
  # dmesg output
  echo "Collecting dmesg logs..."
  dmesg > "$log_dir/dmesg_output.txt"
  
  # kernel logs
  echo "Collecting kernel logs..."
  cp /var/log/kern.log "$log_dir/kernel.log" 2>/dev/null || echo "Kernel log not found"
  
  # syslog
  echo "Collecting syslog..."
  cp /var/log/syslog "$log_dir/syslog.txt" 2>/dev/null || echo "Syslog not found"
  
  # lspci output
  echo "Collecting lspci detailed output..."
  lspci -vvvv > "$log_dir/lspci_full.txt"
  
  # System information
  echo "Collecting system information..."
  uname -a > "$log_dir/uname.txt"
  cat /proc/cpuinfo > "$log_dir/cpuinfo.txt"
  cat /proc/meminfo > "$log_dir/meminfo.txt"
  dmidecode > "$log_dir/dmidecode.txt" 2>/dev/null
  
  # Hardware topology
  echo "Collecting hardware topology..."
  lstopo-no-graphics > "$log_dir/lstopo.txt" 2>/dev/null || echo "lstopo not available"
  
  # BIOS/UEFI information
  echo "Collecting BIOS information..."
  dmidecode -t bios > "$log_dir/bios_info.txt" 2>/dev/null
  
  # PCIe information
  echo "Collecting PCIe information..."
  lspci -t > "$log_dir/lspci_tree.txt"
  # FDisk output
  echo "Collecting disk information..."
  sudo fdisk -l >"$log_dir/fdisk.txt"
}

# Function to unload NVIDIA drivers safely
unload_nvidia_drivers() {
  echo "Attempting to safely unload NVIDIA drivers..."
  
  # Stop ALL related services that might be using NVIDIA
  echo "Stopping NVIDIA and related services..."
  sudo systemctl disable dcgm-exporter && sudo systemctl stop dcgm-exporter
  sudo systemctl stop nvidia-fabricmanager.service
  sudo systemctl stop nvidia-persistenced.service
  sudo rmmod nvidia_uvm nvidia_peermem nvidia_drm nvidia_modeset nvidia
  sudo rmmod nvidia_uvm nvidia_peermem nvidia_drm nvidia_modeset nvidia 
  for service in nvidia-fabricmanager.service nvidia-persistenced.service dcgm-exporter.service nvidia-powerd.service \
                 nvidia-dbus.service nvidia-gridd.service nv-hostengine.service docker kubelet containerd; do
    systemctl stop $service 2>/dev/null
    echo "Attempted to stop $service"
  done
  
  # Disable autoload
  echo "Disabling automatic loading of NVIDIA modules..."
  if [ -f /etc/modprobe.d/nvidia-blacklist.conf ]; then
    echo "Blacklist already exists"
  else
    echo "blacklist nvidia" > /etc/modprobe.d/nvidia-blacklist.conf
    echo "blacklist nvidia_uvm" >> /etc/modprobe.d/nvidia-blacklist.conf
    echo "blacklist nvidia_drm" >> /etc/modprobe.d/nvidia-blacklist.conf
    echo "blacklist nvidia_modeset" >> /etc/modprobe.d/nvidia-blacklist.conf
  fi
  
  # Kill all GPU processes first run didnt catch
  echo "Killing all processes that might be using NVIDIA devices..."
  sudo systemctl disable dcgm-exporter && sudo systemctl stop dcgm-exporter
  sudo systemctl stop nvidia-fabricmanager.service
  sudo systemctl stop nvidia-persistenced.service
  sudo rmmod nvidia_uvm nvidia_peermem nvidia_drm nvidia_modeset nvidia
  sudo rmmod nvidia_uvm nvidia_peermem nvidia_drm nvidia_modeset nvidia 
  # First check with nvidia-smi if available
  if command -v nvidia-smi &> /dev/null; then
    echo "Identifying processes using GPU with nvidia-smi..."
    nvidia_pids=$(nvidia-smi --query-compute-apps=pid --format=csv,noheader 2>/dev/null)
    if [ -n "$nvidia_pids" ]; then
      echo "Found the following PIDs using NVIDIA GPUs:"
      echo "$nvidia_pids"
      for pid in $nvidia_pids; do
        echo "Killing process $pid"
        kill -9 "$pid" 2>/dev/null
      done
    fi
  fi
  
  # Check with lsof for any process using /dev/nvidia*
  echo "Checking for processes using NVIDIA device files..."
  local nvidia_processes=$(lsof /dev/nvidia* 2>/dev/null)
  
  if [ -n "$nvidia_processes" ]; then
    echo "The following processes are using NVIDIA devices:"
    echo "$nvidia_processes"
    
    echo "Automatically killing these processes..."
    local pids=$(lsof /dev/nvidia* 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
    for pid in $pids; do
      echo "Killing process $pid"
      kill -9 "$pid" 2>/dev/null
    done
  fi
  
  # Kill any remaining processes that might be using CUDA/GPU
  echo "Killing any remaining processes that might be using CUDA/GPU..."
  for keyword in nvidia cuda gpu; do
    pids=$(ps aux | grep -i $keyword | grep -v grep | awk '{print $2}')
    for pid in $pids; do
      echo "Killing process $pid (matched $keyword)"
      kill -9 "$pid" 2>/dev/null
    done
  done
  
  # Force close NVIDIA Persistence Daemon if running
  if pgrep -x "nvidia-persistenced" > /dev/null; then
    echo "Force stopping nvidia-persistenced"
    pkill -9 nvidia-persistenced
  fi
  
  # Wait a moment for processes to fully terminate
  echo "Waiting for processes to terminate..."
  sleep 10
  
  # Now try to unload modules with more aggressive approach
  echo "Unloading NVIDIA kernel modules with aggressive approach..."
  
  # First try normal unload sequence
  rmmod nvidia_uvm nvidia_peermem nvidia_drm nvidia_modeset nvidia 2>/dev/null
  
  # If still loaded, try force unload of each module individually
  for module in nvidia_uvm nvidia_peermem nvidia_drm nvidia_modeset nvidia; do
    if lsmod | grep -q "^$module"; then
      echo "Forcefully unloading $module..."
      rmmod -f $module 2>/dev/null
    fi
  done
  
  # If nvidia_uvm is still loaded, try with modprobe
  if lsmod | grep -q "^nvidia_uvm"; then
    echo "Attempting to forcefully unload nvidia_uvm with modprobe..."
    modprobe -r nvidia_uvm
  fi
  
  # Check /proc/driver/nvidia directory
  if [ -d "/proc/driver/nvidia" ]; then
    echo "Found /proc/driver/nvidia directory, this indicates driver is still loaded"
    echo "Contents of /proc/driver/nvidia:"
    ls -la /proc/driver/nvidia/
    
    # For extreme cases, try to kill all user processes (dangerous but effective)
    read -p "Would you like to try killing ALL user processes to unload NVIDIA modules? (extreme measure, y/n): " kill_all_choice
    if [[ "$kill_all_choice" =~ ^[Yy]$ ]]; then
      echo "Killing all user processes except shell and script..."
      current_pid=$$
      parent_pid=$PPID
      for user_pid in $(ps -u $CURRENT_USER -o pid=); do
        if [ "$user_pid" != "$current_pid" ] && [ "$user_pid" != "$parent_pid" ]; then
          echo "Killing user process $user_pid"
          kill -9 "$user_pid" 2>/dev/null
        fi
      done
      sleep 2
      # Try unloading again
      rmmod nvidia_uvm nvidia_peermem nvidia_drm nvidia_modeset nvidia 2>/dev/null
    fi
  fi
  
  # Final check
  if lsmod | grep -q "^nvidia"; then
    echo "Warning: NVIDIA modules could not be completely unloaded."
    echo "Modules still loaded:"
    lsmod | grep nvidia
    
    # Last resort - reboot option
    echo "For a complete unload, a system reboot may be necessary."
    read -p "Would you like to continue anyway? (y/n): " continue_choice
    if [[ "$continue_choice" =~ ^[Yy]$ ]]; then
      return 0
    else
      read -p "Would you like to reboot the system now? (y/n): " reboot_choice
      if [[ "$reboot_choice" =~ ^[Yy]$ ]]; then
        echo "System will reboot in 10 seconds. Please run the script again after reboot."
        sleep 10
        reboot
        exit 0
      else
        return 1
      fi
    fi
  else
    echo "NVIDIA modules successfully unloaded."
    return 0
  fi
  
  return 0
}

# Function to run NVIDIA field diagnostics
run_nvidia_field_diag() {
  local log_dir=$1
  local field_diag_dir=$2
  
  if [ -z "$field_diag_dir" ]; then
    # Prompt user for field diag directory
    read -p "Enter path to NVIDIA field diagnostic package (or press Enter to search): " field_diag_dir
    
    if [ -z "$field_diag_dir" ]; then
      echo "Searching for NVIDIA field diagnostic packages..."
      local found_packages=($(find /home "$PWD" -maxdepth 3 -name "*FLD*.tgz" -o -name "*FLD*.tar.gz" 2>/dev/null))
      
      if [ ${#found_packages[@]} -eq 0 ]; then
        echo "No NVIDIA field diagnostic packages found."
        
        # Ask if user wants to download one
        read -p "Would you like to specify the full path to a package? (y/n): " download_choice
        if [[ "$download_choice" =~ ^[Yy]$ ]]; then
          read -p "Enter full path to NVIDIA field diagnostic package: " field_diag_path
          if [ -f "$field_diag_path" ]; then
            field_diag_dir=$(dirname "$field_diag_path")
            field_diag_file=$(basename "$field_diag_path")
          else
            echo "File not found: $field_diag_path"
            return 1
          fi
        else
          return 1
        fi
      else
        echo "Found the following field diagnostic packages:"
        for i in "${!found_packages[@]}"; do
          echo "$((i+1)). ${found_packages[$i]}"
        done
        
        read -p "Enter package number (1-${#found_packages[@]}): " package_num
        if [[ "$package_num" =~ ^[0-9]+$ ]] && [ "$package_num" -ge 1 ] && [ "$package_num" -le "${#found_packages[@]}" ]; then
          field_diag_path="${found_packages[$((package_num-1))]}"
          field_diag_dir=$(dirname "$field_diag_path")
          field_diag_file=$(basename "$field_diag_path")
        else
          echo "Invalid selection."
          return 1
        fi
      fi
    elif [ -d "$field_diag_dir" ]; then
      # User provided a directory, check for tgz files
      local found_packages=($(find "$field_diag_dir" -maxdepth 1 -name "*FLD*.tgz" -o -name "*FLD*.tar.gz" 2>/dev/null))
      
      if [ ${#found_packages[@]} -eq 0 ]; then
        echo "No NVIDIA field diagnostic packages found in $field_diag_dir."
        return 1
      else
        echo "Found the following field diagnostic packages:"
        for i in "${!found_packages[@]}"; do
          echo "$((i+1)). ${found_packages[$i]}"
        done
        
        read -p "Enter package number (1-${#found_packages[@]}): " package_num
        if [[ "$package_num" =~ ^[0-9]+$ ]] && [ "$package_num" -ge 1 ] && [ "$package_num" -le "${#found_packages[@]}" ]; then
          field_diag_path="${found_packages[$((package_num-1))]}"
          field_diag_file=$(basename "$field_diag_path")
        else
          echo "Invalid selection."
          return 1
        fi
      fi
    elif [ -f "$field_diag_dir" ]; then
      # User provided a file
      field_diag_path="$field_diag_dir"
      field_diag_dir=$(dirname "$field_diag_path")
      field_diag_file=$(basename "$field_diag_path")
    else
      echo "Invalid path: $field_diag_dir"
      return 1
    fi
  fi
  
  # Extract field diagnostic package if needed
  local extracted_dir=""
  if [[ "$field_diag_path" == *.tgz || "$field_diag_path" == *.tar.gz ]]; then
    echo "Extracting NVIDIA field diagnostic package..."
    
    # Create a temporary directory for extraction
    local extract_dir="/tmp/nvidia_fielddiag_extract_$$"
    mkdir -p "$extract_dir"
    
    # Extract the package
    tar -xzf "$field_diag_path" -C "$extract_dir"
    
    # Find the extracted directory
    extracted_dir=$(find "$extract_dir" -maxdepth 1 -type d -name "*FLD*" | head -n 1)
    
    if [ -z "$extracted_dir" ]; then
      # If no directory with FLD in name, use first subdirectory
      extracted_dir=$(find "$extract_dir" -maxdepth 1 -type d -not -path "$extract_dir" | head -n 1)
    fi
    
    if [ -z "$extracted_dir" ]; then
      echo "Failed to extract field diagnostic package or directory structure not recognized."
      rm -rf "$extract_dir"
      return 1
    fi
  else
    # If already extracted
    extracted_dir="$field_diag_path"
  fi
  
  # Check if fieldiag.sh exists
  if [ ! -f "$extracted_dir/fieldiag.sh" ]; then
    echo "fieldiag.sh not found in the extracted directory: $extracted_dir"
    rm -rf "$extract_dir" 2>/dev/null
    return 1
  fi
  
  # Run field diagnostics
  echo "Running NVIDIA field diagnostics..."
  pushd "$extracted_dir" > /dev/null
  
  # Make the script executable if needed
  chmod +x "./fieldiag.sh"
  
  # Run the diagnostics
  echo "Executing field diagnostics with --no_bmc --level2 options..."
  ./fieldiag.sh --no_bmc --level2
  
  # Copy only the specific files we need
  echo "Copying field diagnostic logs to log directory..."
  
  # Copy fieldiag.log if it exists
  if [ -f "./fieldiag.log" ]; then
    echo "Copying fieldiag.log..."
    cp "./fieldiag.log" "$log_dir/"
  fi
  
  # Look for logs directory and find the logs-*.tgz file
  if [ -d "./logs" ]; then
    # Find compressed logs
    local compressed_logs=($(find "./logs" -name "logs-*.tgz" -o -name "logs-*.tar.gz" | sort -r))
    if [ ${#compressed_logs[@]} -gt 0 ]; then
      echo "Copying ${compressed_logs[0]} to log directory..."
      cp "${compressed_logs[0]}" "$log_dir/"
    fi
  fi
  
  popd > /dev/null
  
  # Clean up temporary extraction directory
  if [ -n "$extract_dir" ] && [ -d "$extract_dir" ]; then
    rm -rf "$extract_dir"
  fi
  
  return 0
}

# Function to run NVIDIA bug report
run_nvidia_bug_report() {
  local log_dir=$1
  
  echo "Running NVIDIA bug report..."
  
  # Check if nvidia-bug-report.sh exists
  if ! command -v nvidia-bug-report.sh &> /dev/null; then
    echo "nvidia-bug-report.sh not found. Checking for it in the NVIDIA driver package..."
    
    # Try to find nvidia-bug-report.sh in common locations
    local bug_report_path=""
    for path in "/usr/bin/nvidia-bug-report.sh" "/usr/local/bin/nvidia-bug-report.sh" "/opt/nvidia/bin/nvidia-bug-report.sh"; do
      if [ -f "$path" ]; then
        bug_report_path="$path"
        break
      fi
    done
    
    if [ -z "$bug_report_path" ]; then
      echo "nvidia-bug-report.sh not found. Skipping bug report collection."
      return 1
    fi
  else
    bug_report_path="nvidia-bug-report.sh"
  fi
  
  # Set X authority to avoid X11 forwarding errors
  export XAUTHORITY=$HOME/.Xauthority
  
  # Run the bug report with a 10-minute timeout
  echo "Generating NVIDIA bug report (with 10-minute timeout)..."
  timeout --foreground 600 $bug_report_path
  
  # Check if timeout occurred
  if [ $? -eq 124 ]; then
    echo "Warning: NVIDIA bug report timed out after 10 minutes."
    echo "The partial report will still be collected if available."
  fi
  
  # Move the bug report to the log directory
  local bug_report_file=$(find . -name "nvidia-bug-report*.gz" -type f -newer "$log_dir" | head -n 1)
  if [ -n "$bug_report_file" ]; then
    echo "Moving NVIDIA bug report to log directory..."
    mv "$bug_report_file" "$log_dir/"
    echo "NVIDIA bug report saved as: $log_dir/$(basename "$bug_report_file")"
  else
    echo "Cannot find the generated NVIDIA bug report. It may have been saved in a different location."
    find / -name "nvidia-bug-report*.gz" -type f -newer "$log_dir" -exec cp {} "$log_dir/" \; 2>/dev/null
  fi
  
  return 0
}

# Function to collect NVIDIA GPU logs
collect_nvidia_gpu_logs() {
  local log_dir=$1
  
  echo "Gathering NVIDIA GPU information..."
  
  # Step 1: Basic NVIDIA information first
  if command -v nvidia-smi &> /dev/null; then
    echo "Running nvidia-smi commands..."
    nvidia-smi > "$log_dir/nvidia-smi.txt"
    nvidia-smi -q > "$log_dir/nvidia-smi-query.txt"
    nvidia-smi -q -d PERFORMANCE > "$log_dir/nvidia-smi-performance.txt"
    nvidia-smi -q -d CLOCK > "$log_dir/nvidia-smi-clock.txt"
    nvidia-smi -q -d TEMPERATURE > "$log_dir/nvidia-smi-temp.txt"
    nvidia-smi -q -d POWER > "$log_dir/nvidia-smi-power.txt"
    nvidia-smi -q -d MEMORY > "$log_dir/nvidia-smi-memory.txt"
    nvidia-smi -q -d ECC > "$log_dir/nvidia-smi-ecc.txt"
    nvidia-smi -q -d INFOROM > "$log_dir/nvidia-smi-inforom.txt"
    
    # Additional nvidia-smi commands
    nvidia-smi nvlink -s > "$log_dir/nvidia-smi-nvlink-status.txt" 2>/dev/null
    nvidia-smi nvlink -e > "$log_dir/nvidia-smi-nvlink-errors.txt" 2>/dev/null
    nvidia-smi topo -m > "$log_dir/nvidia-smi-topology.txt" 2>/dev/null
  else
    echo "nvidia-smi not found. Is the NVIDIA driver installed?" > "$log_dir/nvidia-driver-missing.txt"
  fi
  
  # Step 2: Run bug report (doesn't require unloading drivers)
  echo "Running NVIDIA bug report..."
  run_nvidia_bug_report "$log_dir"
  
  # Step 3: Ask to run field diagnostics last
  read -p "Do you want to run NVIDIA field diagnostics? (y/n): " run_field_diag
  if [[ "$run_field_diag" =~ ^[Yy]$ ]]; then
    # Warn user about stopping jobs
    echo "!!! WARNING !!!"
    echo "Field diagnostics require stopping all GPU workloads and unloading NVIDIA drivers."
    echo "Please make sure all GPU jobs are stopped before proceeding."
    read -p "Press Enter to continue or Ctrl+C to abort..."
    
    # Unload drivers safely
    if unload_nvidia_drivers; then
      # Run field diagnostics
      run_nvidia_field_diag "$log_dir"
    else
      echo "Failed to unload NVIDIA drivers. Skipping field diagnostics."
    fi
  fi
}

# Function to collect AMD GPU logs
collect_amd_gpu_logs() {
  local log_dir=$1
  
  echo "Gathering AMD GPU information..."
  
  # Check if rocm-smi is available
  if command -v rocm-smi &> /dev/null; then
    echo "Running rocm-smi commands..."
    rocm-smi > "$log_dir/rocm-smi.txt"
    rocm-smi --showallinfo > "$log_dir/rocm-smi-all.txt"
    rocm-smi --showdriverversion > "$log_dir/rocm-smi-driver.txt"
    rocm-smi --showhw > "$log_dir/rocm-smi-hardware.txt"
    rocm-smi --showtemp > "$log_dir/rocm-smi-temp.txt"
    rocm-smi --showpower > "$log_dir/rocm-smi-power.txt"
    rocm-smi --showmeminfo > "$log_dir/rocm-smi-memory.txt"
    rocm-smi --showpids > "$log_dir/rocm-smi-pids.txt"
    rocm-smi --showperflevel > "$log_dir/rocm-smi-perflevel.txt"
    rocm-smi --showclocks > "$log_dir/rocm-smi-clocks.txt"
    rocm-smi --showvc > "$log_dir/rocm-smi-voltage.txt" 2>/dev/null
    rocm-smi --showtoponuma > "$log_dir/rocm-smi-topology.txt" 2>/dev/null
  else
    echo "rocm-smi not found. Is the ROCm stack installed?" > "$log_dir/amd-driver-missing.txt"
  fi
  
  # Collect AMD GPU specific lspci info
  echo "Collecting AMD GPU lspci info..."
  lspci -vvvv | grep -A 50 -i "AMD.*\[Radeon\|AMD.*\[Vega\|AMD.*\[Navi\|AMD.*\[Arcturus\|AMD.*\[Aldebaran" > "$log_dir/lspci_amd_gpu.txt" 2>/dev/null
  
  # Check for amdgpu module info
  if lsmod | grep -q amdgpu; then
    echo "Collecting amdgpu module info..."
    modinfo amdgpu > "$log_dir/modinfo_amdgpu.txt" 2>/dev/null
  fi
}

# Function to run SOS report
run_sos_report() {
  local log_dir=$1
  
  echo "Running full SOS report (this may take several minutes)..."
  
  # Check if sos package is installed
  if ! command -v sos &> /dev/null && ! command -v sosreport &> /dev/null; then
    echo "SOS package not found. Attempting to install..."
    
    # Try to install sos package based on the distribution
    if command -v dnf &> /dev/null; then
      dnf install -y sos
    elif command -v yum &> /dev/null; then
      yum install -y sos
    elif command -v apt &> /dev/null; then
      apt update && apt install -y sosreport
    elif command -v zypper &> /dev/null; then
      zypper install -y sos
    else
      echo "Unable to install SOS package automatically. Please install it manually and run the script again."
      return 1
    fi
  fi
  
  # Set the output directory for sos report
  local sos_output_dir="$log_dir"
  
  # Run sos report with batch mode (non-interactive) and specify output directory
  echo "Generating full SOS report with all plugins..."
  
  # Get current time for comparison
  local start_time=$(date +%s)
  
  # For RHEL 8+ use 'sos report', for older versions use 'sosreport'
  if command -v sos &> /dev/null; then
    # RHEL 8+ style - run full report without exclusions
    echo "Using 'sos report' command (full report, no exclusions)..."
    timeout --foreground 1800 sos report \
      --batch \
      --tmp-dir="$sos_output_dir" \
      --plugin-timeout=120 \
      --cmd-timeout=60 \
      --threads=4 \
      2>&1 | tee "$log_dir/sos_report_output.log" &
    
    local sos_pid=$!
    
    # Monitor the process and kill if it hangs
    while kill -0 $sos_pid 2>/dev/null; do
      sleep 30
      local current_time=$(date +%s)
      local elapsed=$((current_time - start_time))
      
      if [ $elapsed -gt 1800 ]; then
        echo "SOS report has been running for 30 minutes, terminating..."
        kill -TERM $sos_pid 2>/dev/null
        sleep 10
        kill -KILL $sos_pid 2>/dev/null
        break
      fi
      
      echo "SOS report still running... (${elapsed}s elapsed)"
    done
    
    wait $sos_pid 2>/dev/null
    local exit_code=$?
    
  else
    # Older style - run full report without exclusions
    echo "Using 'sosreport' command (full report, no exclusions)..."
    timeout --foreground 1800 sosreport \
      --batch \
      --tmp-dir="$sos_output_dir" \
      --plugin-timeout=120 \
      2>&1 | tee "$log_dir/sos_report_output.log" &
    
    local sos_pid=$!
    
    # Monitor the process and kill if it hangs
    while kill -0 $sos_pid 2>/dev/null; do
      sleep 30
      local current_time=$(date +%s)
      local elapsed=$((current_time - start_time))
      
      if [ $elapsed -gt 1800 ]; then
        echo "SOS report has been running for 30 minutes, terminating..."
        kill -TERM $sos_pid 2>/dev/null
        sleep 10
        kill -KILL $sos_pid 2>/dev/null
        break
      fi
      
      echo "SOS report still running... (${elapsed}s elapsed)"
    done
    
    wait $sos_pid 2>/dev/null
    local exit_code=$?
  fi
  
  # Check if timeout occurred or process was killed
  if [ $exit_code -eq 124 ] || [ $exit_code -eq 143 ] || [ $exit_code -eq 137 ]; then
    echo "Warning: SOS report was terminated due to timeout or hanging."
    echo "The partial report will still be collected if available."
  elif [ $exit_code -ne 0 ]; then
    echo "Warning: SOS report completed with errors (exit code: $exit_code)."
  else
    echo "SOS report completed successfully."
  fi
  
  # Find the sos report file - it's usually generated in /var/tmp by default
  local sos_files=($(find /var/tmp /tmp -name "sosreport-*.tar.*" -o -name "sos-*.tar.*" -newer "$log_dir" 2>/dev/null))
  
  if [ ${#sos_files[@]} -gt 0 ]; then
    for sos_file in "${sos_files[@]}"; do
      echo "Found SOS report: $sos_file"
      
      # Copy (don't move) the file to our log directory
      cp "$sos_file" "$sos_output_dir/"
      
      # Change ownership of the copied file
      chown "$CURRENT_USER":"$CURRENT_USER" "$sos_output_dir/$(basename "$sos_file")"
      
      echo "SOS report copied to: $sos_output_dir/$(basename "$sos_file")"
      echo "File ownership changed to: $CURRENT_USER"
      
      # Also change ownership of the original file so user can access it directly
      chown "$CURRENT_USER":"$CURRENT_USER" "$sos_file"
      echo "Original SOS report ownership changed: $sos_file"
    done
    echo "SOS report collection completed successfully."
  else
    echo "Warning: Could not find generated SOS report files."
    echo "This might be due to the report being terminated early."
    
    # Try to find any partial files
    local partial_files=($(find /var/tmp /tmp -name "sosreport-*" -o -name "sos-*" 2>/dev/null))
    if [ ${#partial_files[@]} -gt 0 ]; then
      echo "Found partial SOS files:"
      for partial_file in "${partial_files[@]}"; do
        echo "  - $partial_file"
        # Copy partial files too
        cp "$partial_file" "$sos_output_dir/" 2>/dev/null
        chown "$CURRENT_USER":"$CURRENT_USER" "$sos_output_dir/$(basename "$partial_file")" 2>/dev/null
        chown "$CURRENT_USER":"$CURRENT_USER" "$partial_file" 2>/dev/null
      done
    fi
  fi
  
  return 0
}

# Function to download and run ROCm tech support script for Lenovo AMD systems
run_rocm_techsupport() {
  local log_dir=$1
  
  echo "Downloading and running ROCm tech support script for Lenovo AMD system..."
  
  # Create a temporary directory for the script
  local temp_dir=$(mktemp -d)
  local script_path="$temp_dir/rocm_techsupport.sh"
  
  # Download the script
  echo "Downloading rocm_techsupport.sh..."
  if command -v wget &> /dev/null; then
    wget -O "$script_path" --no-cache --no-cookies --no-check-certificate \
      "https://raw.githubusercontent.com/amddcgpuce/rocmtechsupport/master/rocm_techsupport.sh"
  elif command -v curl &> /dev/null; then
    curl -L -o "$script_path" \
      "https://raw.githubusercontent.com/amddcgpuce/rocmtechsupport/master/rocm_techsupport.sh"
  else
    echo "Error: Neither wget nor curl found. Cannot download ROCm tech support script."
    rm -rf "$temp_dir"
    return 1
  fi
  
  # Check if download was successful
  if [ ! -f "$script_path" ] || [ ! -s "$script_path" ]; then
    echo "Error: Failed to download ROCm tech support script."
    rm -rf "$temp_dir"
    return 1
  fi
  
  # Make the script executable
  chmod +x "$script_path"
  
  # Run the script and capture output
  echo "Running ROCm tech support script (this may take several minutes)..."
  local output_file="$log_dir/rocm_techsupport_$(hostname)_$(date +"%y-%m-%d-%H-%M-%S").log"
  
  # Run with timeout of 20 minutes
  timeout --foreground 1200 sh "$script_path" > "$output_file" 2>&1
  
  # Check if timeout occurred
  if [ $? -eq 124 ]; then
    echo "Warning: ROCm tech support script timed out after 20 minutes." >> "$output_file"
    echo "Warning: ROCm tech support script timed out after 20 minutes."
  fi
  
  # Check if output file was created and has content
  if [ -f "$output_file" ] && [ -s "$output_file" ]; then
    echo "ROCm tech support log saved as: $(basename "$output_file")"
  else
    echo "Warning: ROCm tech support script did not generate expected output."
  fi
  
  # Clean up temporary directory
  rm -rf "$temp_dir"
  
  return 0
}

# Available vendors
VENDORS=("SuperMicro" "Lenovo" "ASUS" "Dell" "Gigabyte" "Aivres")
# Available GPU types
GPU_TYPES=("AMD" "NVIDIA")

# Ask for vendor
echo "RMA GPU Log Collection Tool"
echo "==========================="
echo "Please select the vendor:"
for i in "${!VENDORS[@]}"; do
  echo "$((i+1)). ${VENDORS[$i]}"
done

while true; do
  read -p "Enter vendor number (1-${#VENDORS[@]}): " vendor_num
  if [[ "$vendor_num" =~ ^[0-9]+$ ]] && [ "$vendor_num" -ge 1 ] && [ "$vendor_num" -le "${#VENDORS[@]}" ]; then
    VENDOR="${VENDORS[$((vendor_num-1))]}"
    break
  else
    echo "Invalid selection. Please enter a number between 1 and ${#VENDORS[@]}."
  fi
done

# Ask for GPU type
echo -e "\nPlease select the GPU type:"
for i in "${!GPU_TYPES[@]}"; do
  echo "$((i+1)). ${GPU_TYPES[$i]}"
done

while true; do
  read -p "Enter GPU type number (1-${#GPU_TYPES[@]}): " gpu_type_num
  if [[ "$gpu_type_num" =~ ^[0-9]+$ ]] && [ "$gpu_type_num" -ge 1 ] && [ "$gpu_type_num" -le "${#GPU_TYPES[@]}" ]; then
    GPU_TYPE="${GPU_TYPES[$((gpu_type_num-1))]}"
    break
  else
    echo "Invalid selection. Please enter a number between 1 and ${#GPU_TYPES[@]}."
  fi
done

# Ask for GPU name (optional)
read -p "Enter GPU name (optional, press Enter to skip): " GPU_NAME

# Create folder structure
if [ -n "$GPU_NAME" ]; then
  BASE_DIR="/tmp/gpu_rma_${VENDOR}_${GPU_TYPE}_${GPU_NAME}_${TIMESTAMP}"
else
  BASE_DIR="/tmp/gpu_rma_${VENDOR}_${GPU_TYPE}_${TIMESTAMP}"
fi

# Create only 3 directories as requested
SYSTEM_LOG_DIR="$BASE_DIR/system_logs"
GPU_LOG_DIR="$BASE_DIR/gpu_logs"
VENDOR_LOG_DIR="$BASE_DIR/vendor_logs"

mkdir -p "$SYSTEM_LOG_DIR"
mkdir -p "$GPU_LOG_DIR"
mkdir -p "$VENDOR_LOG_DIR"

echo -e "\nStarting log collection process..."
echo "=================================="

# Step 1: Collect system logs first
echo -e "\n[1/3] Collecting system logs..."
collect_system_logs "$SYSTEM_LOG_DIR"

# Step 2: Collect GPU-specific logs
echo -e "\n[2/3] Collecting GPU-specific logs..."
case "$GPU_TYPE" in
  "NVIDIA")
    # Only create gpu_logs directory for NVIDIA systems
    collect_nvidia_gpu_logs "$GPU_LOG_DIR"
    ;;
  
  "AMD")
    # Only create gpu_logs directory for AMD systems
    collect_amd_gpu_logs "$GPU_LOG_DIR"
    ;;
  
  *)
    echo "No specific GPU logs available for $GPU_TYPE"
    # Remove the gpu_logs directory if no GPU type matched
    rmdir "$GPU_LOG_DIR" 2>/dev/null
    ;;
esac

# Step 3: Run vendor-specific scripts
echo -e "\n[3/3] Running vendor-specific scripts..."
case "$VENDOR" in
  "Lenovo")
    echo "Running Lenovo-specific scripts..."
    
    # For Lenovo AMD systems, run ROCm tech support first
    if [[ "$GPU_TYPE" == "AMD" ]]; then
      echo "Running ROCm tech support script for Lenovo AMD system..."
      run_rocm_techsupport "$VENDOR_LOG_DIR"
    fi
    
    # Then run SOS report for Lenovo systems (always runs last)
    echo "Running SOS report for Lenovo system (this will be the final step)..."
    run_sos_report "$VENDOR_LOG_DIR"
    ;;
  
  "SuperMicro"|"ASUS"|"Dell"|"Gigabyte"|"Aivres")
    echo "No vendor-specific scripts available for $VENDOR yet."
    # Create a placeholder file to indicate no vendor scripts were run
    echo "No vendor-specific scripts available for $VENDOR at this time." > "$VENDOR_LOG_DIR/no_vendor_scripts.txt"
    echo "Timestamp: $(date)" >> "$VENDOR_LOG_DIR/no_vendor_scripts.txt"
    ;;
  
  *)
    echo "Unknown vendor: $VENDOR"
    echo "Unknown vendor: $VENDOR" > "$VENDOR_LOG_DIR/unknown_vendor.txt"
    echo "Timestamp: $(date)" >> "$VENDOR_LOG_DIR/unknown_vendor.txt"
    ;;
esac

# Create a summary file
echo -e "\nCreating summary file..."
cat > "$BASE_DIR/summary.txt" << EOF
RMA Log Collection Summary
=========================
Date: $(date)
Vendor: $VENDOR
GPU Type: $GPU_TYPE
GPU Name: ${GPU_NAME:-"Not specified"}
Hostname: $(hostname)
Kernel: $(uname -r)
Driver: $(if [ "$GPU_TYPE" == "NVIDIA" ] && command -v nvidia-smi &> /dev/null; then nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1; elif [ "$GPU_TYPE" == "AMD" ] && command -v rocm-smi &> /dev/null; then rocm-smi --showdriverversion 2>/dev/null | grep -oP 'Driver:\s*\K.+' | head -n1; else echo "Unknown"; fi)

Files collected:
EOF

# Add directory summaries only if they exist and have files
if [ -d "$SYSTEM_LOG_DIR" ] && [ "$(ls -A "$SYSTEM_LOG_DIR" 2>/dev/null)" ]; then
  echo "- System logs: $(ls -1 "$SYSTEM_LOG_DIR" 2>/dev/null | wc -l) files" >> "$BASE_DIR/summary.txt"
fi

if [ -d "$GPU_LOG_DIR" ] && [ "$(ls -A "$GPU_LOG_DIR" 2>/dev/null)" ]; then
  echo "- GPU logs: $(ls -1 "$GPU_LOG_DIR" 2>/dev/null | wc -l) files" >> "$BASE_DIR/summary.txt"
  
  # Add specific NVIDIA diagnostic info if present
  if [ "$GPU_TYPE" == "NVIDIA" ]; then
    local bug_reports=$(find "$GPU_LOG_DIR" -name "nvidia-bug-report*.gz" 2>/dev/null | wc -l)
    local field_diag_logs=$(find "$GPU_LOG_DIR" -name "logs-*.tgz" -o -name "fieldiag.log" 2>/dev/null | wc -l)
    
    if [ "$bug_reports" -gt 0 ] || [ "$field_diag_logs" -gt 0 ]; then
      echo "  - NVIDIA bug reports: $bug_reports file(s)" >> "$BASE_DIR/summary.txt"
      echo "  - Field diagnostic files: $field_diag_logs file(s)" >> "$BASE_DIR/summary.txt"
    fi
  fi
fi

if [ -d "$VENDOR_LOG_DIR" ] && [ "$(ls -A "$VENDOR_LOG_DIR" 2>/dev/null)" ]; then
  echo "- Vendor logs: $(ls -1 "$VENDOR_LOG_DIR" 2>/dev/null | wc -l) files" >> "$BASE_DIR/summary.txt"
  
  # Add specific info for Lenovo AMD systems
  if [ "$VENDOR" == "Lenovo" ] && [ "$GPU_TYPE" == "AMD" ]; then
    local rocm_logs=$(find "$VENDOR_LOG_DIR" -name "rocm_techsupport_*.log" 2>/dev/null | wc -l)
    if [ "$rocm_logs" -gt 0 ]; then
      echo "  - ROCm tech support logs: $rocm_logs file(s)" >> "$BASE_DIR/summary.txt"
    fi
  fi
  
  # Add SOS report info if present
  local sos_reports=$(find "$VENDOR_LOG_DIR" -name "sosreport-*.tar.*" -o -name "sos-*.tar.*" 2>/dev/null | wc -l)
  if [ "$sos_reports" -gt 0 ]; then
    echo "  - SOS reports: $sos_reports file(s)" >> "$BASE_DIR/summary.txt"
  fi
fi

# Set permissions
echo "Setting permissions..."
chown -R "$CURRENT_USER":"$CURRENT_USER" "$BASE_DIR"

echo -e "\nLog collection complete!"
echo "All logs have been saved to: $BASE_DIR"

# Create a tar archive for easy download
TAR_FILE="${BASE_DIR}.tar.gz"
echo -e "\nCreating compressed archive: $TAR_FILE"
tar -czf "$TAR_FILE" -C "$(dirname "$BASE_DIR")" "$(basename "$BASE_DIR")"
chown "$CURRENT_USER":"$CURRENT_USER" "$TAR_FILE"

echo "Compressed archive created: $TAR_FILE"

# Display collection summary
echo -e "\n=== COLLECTION SUMMARY ==="
echo "Total directories: $(find "$BASE_DIR" -type d | wc -l)"
echo "Total files collected: $(find "$BASE_DIR" -type f | wc -l)"
echo "Archive size: $(du -h "$TAR_FILE" | cut -f1)"
echo -e "\nFiles ready for RMA submission!"
echo "Please attach the compressed archive: $TAR_FILE"