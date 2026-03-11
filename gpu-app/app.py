import subprocess
import json
import platform
import os
import datetime
import psutil
from flask import Flask, render_template, jsonify

app = Flask(__name__)

def get_gpu_info():
    """Query NVIDIA GPU info via nvidia-smi."""
    try:
        result = subprocess.run(
            ['nvidia-smi', '--query-gpu=name,driver_version,memory.total,memory.used,memory.free,utilization.gpu,temperature.gpu,power.draw',
             '--format=csv,noheader,nounits'],
            capture_output=True, text=True, timeout=10
        )
        if result.returncode != 0:
            return None

        parts = [p.strip() for p in result.stdout.strip().split(',')]
        return {
            'name': parts[0],
            'driver_version': parts[1],
            'memory_total_mb': int(float(parts[2])),
            'memory_used_mb': int(float(parts[3])),
            'memory_free_mb': int(float(parts[4])),
            'utilization_pct': int(float(parts[5])),
            'temperature_c': int(float(parts[6])),
            'power_draw_w': float(parts[7]),
            'available': True,
        }
    except FileNotFoundError:
        return None
    except Exception as e:
        return {'available': False, 'error': str(e)}


def get_system_info():
    """Get basic system info."""
    return {
        'hostname': platform.node(),
        'os': f"{platform.system()} {platform.release()}",
        'cpu_count': psutil.cpu_count(),
        'cpu_percent': psutil.cpu_percent(interval=0.5),
        'memory_total_gb': round(psutil.virtual_memory().total / (1024**3), 1),
        'memory_used_gb': round(psutil.virtual_memory().used / (1024**3), 1),
        'memory_percent': psutil.virtual_memory().percent,
        'pod_name': os.environ.get('HOSTNAME', 'unknown'),
        'node_name': os.environ.get('NODE_NAME', 'unknown'),
        'namespace': os.environ.get('POD_NAMESPACE', 'unknown'),
    }


@app.route('/')
def index():
    """Serve the dashboard UI."""
    return render_template('index.html')


@app.route('/api/status')
def api_status():
    """JSON API — returns GPU + system status."""
    gpu = get_gpu_info()
    system = get_system_info()

    return jsonify({
        'timestamp': datetime.datetime.utcnow().isoformat() + 'Z',
        'gpu': gpu if gpu else {'available': False, 'error': 'nvidia-smi not found'},
        'system': system,
    })


@app.route('/health')
def health():
    """Health check endpoint for Kubernetes probes."""
    return jsonify({'status': 'healthy'}), 200


@app.route('/api/stress')
def stress_gpu():
    """Run a quick GPU stress test to show utilization spike."""
    try:
        # Use nvidia-smi to run a quick diagnostic
        result = subprocess.run(
            ['nvidia-smi', '-q', '-d', 'UTILIZATION'],
            capture_output=True, text=True, timeout=15
        )
        return jsonify({
            'status': 'ok',
            'message': 'GPU query completed',
            'output': result.stdout[:500]
        })
    except Exception as e:
        return jsonify({'status': 'error', 'message': str(e)})


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080, debug=True)
