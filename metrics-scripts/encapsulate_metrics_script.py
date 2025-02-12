import os
import re
import glob
import gzip
import sys
from datetime import datetime, timedelta
from dateutil import parser
import requests

# Node configurations
NODE_CONFIGS = {
    # Validator
    'validator': {
        'parent_dir': '/opt/supra/log',
        'log_pattern': 'supra.log',
        'rpc_urls': {
            'mainnet': 'https://rpc-mainnet.supra.com/rpc/v1/block',
            'testnet': 'https://rpc-testnet.supra.com/rpc/v1/block'
        }
    },
    # Fullnode
    'fullnode': {
        'parent_dir': '/opt/supra-fullnode/log',
        'log_pattern': 'supra-fullnode.log',
        'rpc_urls': {
            'mainnet': 'https://rpc-mainnet.supra.com/rpc/v1/block',
            'testnet': 'https://rpc-testnet.supra.com/rpc/v1/block'
        }
    }
}

def get_node_config():
    """Get node configuration based on command line arguments."""
    if len(sys.argv) != 3:
        print("Usage: python3 script.py <node-type> <network>")
        print("Node types: validator, fullnode")
        print("Networks: mainnet, testnet")
        sys.exit(1)
    
    node_type = sys.argv[1]
    network = sys.argv[2]
    
    if node_type not in NODE_CONFIGS:
        print(f"Invalid node type. Available types: validator, fullnode")
        sys.exit(1)
    
    if network not in ['mainnet', 'testnet']:
        print("Invalid network. Available networks: mainnet, testnet")
        sys.exit(1)

    config = {
        'log_dir': NODE_CONFIGS[node_type]['parent_dir'],
        'log_pattern': NODE_CONFIGS[node_type]['log_pattern'],
        'rpc_url': NODE_CONFIGS[node_type]['rpc_urls'][network]
    }
    
    return config

def find_latest_log_file(config):
    """Finds the latest log file based on modification time."""
    files = sorted(glob.glob(f"{config['log_dir']}/{config['log_pattern']}"), 
                  key=os.path.getmtime, reverse=True)
    return files[0] if files else None

def parse_timestamp_ns(line):
    """Parses timestamp from log line and converts to nanoseconds."""
    match = re.search(r"\[([^\]]+)\]", line)
    if match:
        timestamp_str = match.group(1).replace("Z+00:00", "")
        try:
            timestamp_dt = parser.isoparse(timestamp_str)
            return int(timestamp_dt.timestamp() * 1e9)
        except ValueError:
            return None
    return None

def calculate_block_time(config):
    """Calculate block round and height time."""
    latest_log = find_latest_log_file(config)
    if not latest_log:
        return None, None

    last_round, last_round_ts = None, None
    second_last_round, second_last_round_ts = None, None
    last_height, last_height_ts = None, None
    second_last_height, second_last_height_ts = None, None

    with open(latest_log, "r") as f:
        for line in f:
            ts = parse_timestamp_ns(line)
            if not ts:
                continue

            if "Block round" in line:
                match = re.search(r"Block round: \((\d+)\)", line)
                if match:
                    round_num = int(match.group(1))
                    if last_round is not None:
                        second_last_round, second_last_round_ts = last_round, last_round_ts
                    last_round, last_round_ts = round_num, ts

            if "Block height" in line:
                match = re.search(r"Block height: \((\d+)\)", line)
                if match:
                    height = int(match.group(1))
                    if last_height is not None:
                        second_last_height, second_last_height_ts = last_height, last_height_ts
                    last_height, last_height_ts = height, ts

    round_time = None
    height_time = None

    if second_last_round is not None and last_round != second_last_round:
        round_time = (last_round_ts - second_last_round_ts) / 1e9

    if second_last_height is not None and last_height != second_last_height:
        height_time = (last_height_ts - second_last_height_ts) / 1e9

    return round_time, height_time

def extract_latest_metrics(config):
    """Extract latest block metrics from log file."""
    latest_log = find_latest_log_file(config)
    if not latest_log:
        return {'height': 0, 'epoch': 0, 'round': 0}

    block_pattern = r"INFO .*?Executed Block hash: \([a-f0-9]+\), Block height: \((\d+)\), Block round: \((\d+)\), Block epoch: \((\d+)\)"

    try:
        with open(latest_log, 'r') as file:
            for line in reversed(file.readlines()):
                match = re.search(block_pattern, line)
                if match:
                    return {
                        'height': int(match.group(1)),
                        'round': int(match.group(2)),
                        'epoch': int(match.group(3))
                    }
    except Exception as e:
        print(f"Error reading log file: {e}")
    
    return {'height': 0, 'epoch': 0, 'round': 0}

def fetch_api_block_metrics(config):
    """Fetch current block metrics from API."""
    try:
        response = requests.get(config['rpc_url'])
        response.raise_for_status()
        data = response.json()
        return {
            'height': int(data['height']),
            'epoch': int(data['view']['epoch_id']['epoch'])
        }
    except Exception:
        return None

def print_all_metrics():
    """Print all metrics in Prometheus format."""
    config = get_node_config()
    metrics = extract_latest_metrics(config)
    
    print(f"supra_latest_block_height {metrics['height']}")
    print(f"supra_latest_block_epoch {metrics['epoch']}")
    print(f"supra_latest_block_round {metrics['round']}")

    # Block times
    round_time, height_time = calculate_block_time(config)
    if round_time is not None:
        print(f"supra_block_round_time {round_time:.7f}")
    
    if height_time is not None:
        print(f"supra_block_height_time {height_time:.7f}")

    # Sync status
    api_metrics = fetch_api_block_metrics(config)
    if api_metrics:
        height_diff = api_metrics['height'] - metrics['height']
        epoch_diff = api_metrics['epoch'] - metrics['epoch']
        
        status_code = 0 if height_diff <= 100 and epoch_diff <= 0 else 1
        print(f"supra_node_sync_status {status_code}")

if __name__ == "__main__":
    print_all_metrics()
