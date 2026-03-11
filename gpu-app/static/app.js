// ─── GPU Node Dashboard — Frontend ──────────────────────
const POLL_INTERVAL = 5000;  // 5 seconds
let pollTimer = null;

async function fetchStatus() {
    try {
        const res = await fetch('/api/status');
        if (!res.ok) throw new Error(`HTTP ${res.status}`);
        const data = await res.json();
        renderGPU(data.gpu);
        renderSystem(data.system);
        renderK8s(data.system);
        updateConnection(true);
        updateTimestamp(data.timestamp);
    } catch (err) {
        console.error('Fetch error:', err);
        updateConnection(false);
    }
}

// ─── GPU Card ────────────────────────────────────────────
function renderGPU(gpu) {
    const card = document.getElementById('gpuCard');
    const content = document.getElementById('gpuContent');
    const chip = document.getElementById('gpuChip');

    if (!gpu || !gpu.available) {
        card.classList.remove('has-gpu');
        chip.textContent = 'Not Detected';
        chip.className = 'chip offline';
        content.innerHTML = `
            <div class="no-gpu">
                <div class="icon">🔌</div>
                <h3>No GPU Detected</h3>
                <p>This pod is not running on a GPU node, or NVIDIA drivers aren't installed yet.</p>
            </div>`;
        return;
    }

    card.classList.add('has-gpu');
    chip.textContent = 'Online';
    chip.className = 'chip online';

    const memPct = Math.round((gpu.memory_used_mb / gpu.memory_total_mb) * 100);
    const memBarClass = memPct > 80 ? 'high' : '';
    const utilColor = gpu.utilization_pct > 80 ? 'red' : gpu.utilization_pct > 40 ? 'amber' : 'green';
    const tempColor = gpu.temperature_c > 80 ? 'red' : gpu.temperature_c > 60 ? 'amber' : 'green';

    content.innerHTML = `
        <div class="gpu-name">
            <span class="icon">⚡</span>
            ${gpu.name} &nbsp;•&nbsp; Driver ${gpu.driver_version}
        </div>

        <div class="memory-bar-container">
            <div class="memory-bar-label">
                <span>VRAM Usage</span>
                <span>${gpu.memory_used_mb} / ${gpu.memory_total_mb} MB (${memPct}%)</span>
            </div>
            <div class="memory-bar">
                <div class="memory-bar-fill ${memBarClass}" style="width: ${memPct}%"></div>
            </div>
        </div>

        <div class="gpu-stats">
            <div class="stat-box">
                <div class="stat-label">GPU Utilization</div>
                <div class="stat-value ${utilColor}">${gpu.utilization_pct}<span class="stat-unit">%</span></div>
            </div>
            <div class="stat-box">
                <div class="stat-label">Temperature</div>
                <div class="stat-value ${tempColor}">${gpu.temperature_c}<span class="stat-unit">°C</span></div>
            </div>
            <div class="stat-box">
                <div class="stat-label">Memory Free</div>
                <div class="stat-value blue">${gpu.memory_free_mb}<span class="stat-unit">MB</span></div>
            </div>
            <div class="stat-box">
                <div class="stat-label">Power Draw</div>
                <div class="stat-value">${gpu.power_draw_w}<span class="stat-unit">W</span></div>
            </div>
        </div>`;
}

// ─── System Card ─────────────────────────────────────────
function renderSystem(sys) {
    document.getElementById('systemGrid').innerHTML = `
        <div class="info-item">
            <span class="label">Hostname</span>
            <span class="value">${sys.hostname}</span>
        </div>
        <div class="info-item">
            <span class="label">OS</span>
            <span class="value">${sys.os}</span>
        </div>
        <div class="info-item">
            <span class="label">CPUs</span>
            <span class="value">${sys.cpu_count} cores • ${sys.cpu_percent}%</span>
        </div>
        <div class="info-item">
            <span class="label">Memory</span>
            <span class="value">${sys.memory_used_gb}/${sys.memory_total_gb} GB (${sys.memory_percent}%)</span>
        </div>`;
}

// ─── Kubernetes Card ─────────────────────────────────────
function renderK8s(sys) {
    document.getElementById('k8sGrid').innerHTML = `
        <div class="info-item">
            <span class="label">Pod</span>
            <span class="value">${sys.pod_name}</span>
        </div>
        <div class="info-item">
            <span class="label">Node</span>
            <span class="value">${sys.node_name}</span>
        </div>
        <div class="info-item">
            <span class="label">Namespace</span>
            <span class="value">${sys.namespace}</span>
        </div>`;
}

// ─── Connection Badge ────────────────────────────────────
function updateConnection(online) {
    const badge = document.getElementById('connectionBadge');
    const text = document.getElementById('connectionText');
    badge.className = `status-badge ${online ? 'online' : 'offline'}`;
    text.textContent = online ? 'Connected' : 'Disconnected';
}

function updateTimestamp(ts) {
    const d = new Date(ts);
    document.getElementById('lastUpdated').textContent =
        `Last updated: ${d.toLocaleTimeString()}`;
}

// ─── Start polling ───────────────────────────────────────
fetchStatus();
pollTimer = setInterval(fetchStatus, POLL_INTERVAL);
