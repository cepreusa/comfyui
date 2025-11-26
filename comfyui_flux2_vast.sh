#!/bin/bash
# =========================================
# ComfyUI + Flux 2 Provisioning Script for Vast.ai
# =========================================

# =========================================
# Переменные
# =========================================
UBUNTU_HOME="/home/ubuntu"
COMFYUI_DIR="${UBUNTU_HOME}/ComfyUI"
VENV_DIR="${UBUNTU_HOME}/venv"
LOG_DIR="/var/log/comfyui"
SUPERVISOR_CONF="/etc/supervisor/conf.d/comfyui.conf"

# Порт ComfyUI (можно изменить)
COMFYUI_PORT="${COMFYUI_PORT:-8188}"

# Авторизация (из переменных окружения)
COMFYUI_AUTH_USER="${COMFYUI_AUTH_USER:-admin}"
COMFYUI_AUTH_PASS="${COMFYUI_AUTH_PASS:-changeme}"

APT_PACKAGES=(
    git
    bc
    wget
    curl
    software-properties-common
    libgl1-mesa-glx
    libglib2.0-0
)

# Custom Nodes для ComfyUI
CUSTOM_NODES=(
    "https://github.com/ltdrdata/ComfyUI-Manager.git"
    "https://github.com/city96/ComfyUI-GGUF.git"
    "https://github.com/BadCafeCode/apitools-comfyui.git"
    "https://github.com/BadCafeCode/masquerade-nodes-comfyui.git"
)

# Flux 2 Модели
# VAE
FLUX2_VAE_URL="https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/vae/flux2-vae.safetensors"

# Text Encoder (Mistral FP8 - ~12GB)
FLUX2_TEXT_ENCODER_URL="https://huggingface.co/Comfy-Org/flux2-dev/resolve/main/split_files/text_encoders/mistral_3_small_flux2_fp8.safetensors"

# GGUF Model (Q4_K_M - оптимально для 24GB VRAM на 4090)
FLUX2_GGUF_URL="https://huggingface.co/city96/FLUX.2-dev-gguf/resolve/main/flux2-dev-Q4_K_M.gguf"

# =========================================
# Основные функции
# =========================================

provisioning_print_header() {
    echo "##############################################"
    echo "# Starting ComfyUI + Flux 2 provisioning..."
    echo "# Port: ${COMFYUI_PORT}"
    echo "##############################################"
}

provisioning_print_end() {
    echo "##############################################"
    echo "# Provisioning complete! ComfyUI is ready."
    echo "# Web UI: http://localhost:${COMFYUI_PORT}"
    echo "# API: http://localhost:${COMFYUI_PORT}/api"
    echo "# Logs: ${LOG_DIR}/comfyui.log"
    echo "##############################################"
}

# Создание пользователя ubuntu
provisioning_create_ubuntu_user() {
    echo "Проверяем права пользователя ubuntu..."

    if id ubuntu &>/dev/null; then
        echo "Пользователь ubuntu найден."
        
        if id -nG ubuntu | grep -qw "sudo"; then
            echo "У пользователя ubuntu уже есть права sudo."
        else
            echo "Добавляем ubuntu в группу sudo..."
            usermod -aG sudo ubuntu
        fi

        if [[ ! -f /etc/sudoers.d/90-ubuntu ]]; then
            echo "Создаём /etc/sudoers.d/90-ubuntu..."
            echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ubuntu
            chmod 440 /etc/sudoers.d/90-ubuntu
        fi
    else
        echo "Пользователь ubuntu не найден. Создаём нового..."
        adduser --disabled-password --gecos "" ubuntu
        usermod -aG sudo ubuntu
        echo "ubuntu ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-ubuntu
        chmod 440 /etc/sudoers.d/90-ubuntu
    fi
}

# Установка системных пакетов
provisioning_get_apt_packages() {
    echo "Устанавливаем системные пакеты..."
    apt-get update
    apt-get install -y "${APT_PACKAGES[@]}"
}

# Установка Python 3.10
provisioning_install_python() {
    echo "Устанавливаем Python 3.10..."
    add-apt-repository ppa:deadsnakes/ppa -y
    apt-get update
    apt-get install -y python3.10 python3.10-venv python3.10-dev python3-pip
}

# Создание виртуального окружения
provisioning_setup_venv() {
    if [[ ! -d "${VENV_DIR}" ]]; then
        echo "Создаём виртуальное окружение..."
        sudo -u ubuntu python3.10 -m venv "${VENV_DIR}"
    else
        echo "Виртуальное окружение уже существует."
    fi
    
    # Активируем и обновляем pip
    sudo -u ubuntu "${VENV_DIR}/bin/pip" install --upgrade pip
}

# Клонирование ComfyUI
provisioning_clone_comfyui() {
    if [[ ! -d "${COMFYUI_DIR}" ]]; then
        echo "Клонируем ComfyUI..."
        sudo -u ubuntu git clone https://github.com/comfyanonymous/ComfyUI.git "${COMFYUI_DIR}"
    else
        echo "ComfyUI уже существует, обновляем..."
        cd "${COMFYUI_DIR}"
        sudo -u ubuntu git pull
    fi
    
    # Устанавливаем зависимости ComfyUI
    echo "Устанавливаем зависимости ComfyUI..."
    sudo -u ubuntu "${VENV_DIR}/bin/pip" install -r "${COMFYUI_DIR}/requirements.txt"
    
    # Устанавливаем PyTorch с CUDA (для 4090)
    echo "Устанавливаем PyTorch с CUDA..."
    sudo -u ubuntu "${VENV_DIR}/bin/pip" install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
}

# Установка Custom Nodes
provisioning_get_custom_nodes() {
    echo "Устанавливаем Custom Nodes..."
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/custom_nodes"
    
    for repo in "${CUSTOM_NODES[@]}"; do
        dir="${repo##*/}"
        dir="${dir%.git}"
        target="${COMFYUI_DIR}/custom_nodes/${dir}"
        
        if [[ ! -d "$target" ]]; then
            echo "Скачиваем: $dir"
            sudo -u ubuntu git clone "$repo" "$target" --recursive
            
            # Устанавливаем зависимости если есть requirements.txt
            if [[ -f "${target}/requirements.txt" ]]; then
                echo "Устанавливаем зависимости для $dir..."
                sudo -u ubuntu "${VENV_DIR}/bin/pip" install -r "${target}/requirements.txt"
            fi
        else
            echo "$dir уже установлен, обновляем..."
            cd "$target"
            sudo -u ubuntu git pull
        fi
    done
    
    # Дополнительно устанавливаем gguf для ComfyUI-GGUF
    echo "Устанавливаем gguf пакет..."
    sudo -u ubuntu "${VENV_DIR}/bin/pip" install --upgrade gguf
}

# Создание структуры папок для моделей
provisioning_create_model_dirs() {
    echo "Создаём структуру папок для моделей..."
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/models/unet"
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/models/diffusion_models"
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/models/vae"
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/models/text_encoders"
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/models/clip"
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/models/checkpoints"
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/models/loras"
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/input"
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/output"
}

# Загрузка модели с прогрессом
download_model() {
    local url="$1"
    local target_dir="$2"
    local filename=$(basename "$url")
    local target_path="${target_dir}/${filename}"
    
    if [[ ! -f "$target_path" ]]; then
        echo "Скачиваем: $filename"
        sudo -u ubuntu wget -q --show-progress -c -O "$target_path" "$url"
        echo "✓ $filename скачан"
    else
        echo "✓ $filename уже существует"
    fi
}

# Загрузка Flux 2 моделей
provisioning_get_flux2_models() {
    echo ""
    echo "=========================================="
    echo "Загружаем Flux 2 модели..."
    echo "Это займёт некоторое время (~30GB)"
    echo "=========================================="
    
    # VAE (~300MB)
    echo ""
    echo "1/3 Скачиваем VAE..."
    download_model "$FLUX2_VAE_URL" "${COMFYUI_DIR}/models/vae"
    
    # Text Encoder (~12GB)
    echo ""
    echo "2/3 Скачиваем Mistral Text Encoder (FP8)..."
    download_model "$FLUX2_TEXT_ENCODER_URL" "${COMFYUI_DIR}/models/text_encoders"
    
    # GGUF Model (~18.7GB)
    echo ""
    echo "3/3 Скачиваем Flux 2 GGUF модель (Q4_K_M)..."
    download_model "$FLUX2_GGUF_URL" "${COMFYUI_DIR}/models/unet"
    
    echo ""
    echo "✓ Все Flux 2 модели загружены!"
}

# Создание default workflow для Flux 2
provisioning_create_default_workflow() {
    echo "Создаём default workflow для Flux 2..."
    
    cat > "${COMFYUI_DIR}/user/default/workflows/flux2_default.json" <<'WORKFLOW_EOF'
{
  "last_node_id": 12,
  "last_link_id": 11,
  "nodes": [
    {
      "id": 1,
      "type": "UnetLoaderGGUF",
      "pos": [50, 100],
      "size": [315, 58],
      "flags": {},
      "order": 0,
      "mode": 0,
      "outputs": [{"name": "MODEL", "type": "MODEL", "links": [1], "slot_index": 0}],
      "properties": {"Node name for S&R": "UnetLoaderGGUF"},
      "widgets_values": ["flux2-dev-Q4_K_M.gguf"]
    },
    {
      "id": 2,
      "type": "CLIPLoader",
      "pos": [50, 200],
      "size": [315, 82],
      "flags": {},
      "order": 1,
      "mode": 0,
      "outputs": [{"name": "CLIP", "type": "CLIP", "links": [2], "slot_index": 0}],
      "properties": {"Node name for S&R": "CLIPLoader"},
      "widgets_values": ["mistral_3_small_flux2_fp8.safetensors", "flux"]
    },
    {
      "id": 3,
      "type": "VAELoader",
      "pos": [50, 320],
      "size": [315, 58],
      "flags": {},
      "order": 2,
      "mode": 0,
      "outputs": [{"name": "VAE", "type": "VAE", "links": [3], "slot_index": 0}],
      "properties": {"Node name for S&R": "VAELoader"},
      "widgets_values": ["flux2-vae.safetensors"]
    },
    {
      "id": 4,
      "type": "CLIPTextEncode",
      "pos": [450, 100],
      "size": [400, 200],
      "flags": {},
      "order": 4,
      "mode": 0,
      "inputs": [{"name": "clip", "type": "CLIP", "link": 2}],
      "outputs": [{"name": "CONDITIONING", "type": "CONDITIONING", "links": [4], "slot_index": 0}],
      "properties": {"Node name for S&R": "CLIPTextEncode"},
      "widgets_values": ["A photorealistic portrait of a young woman, soft natural lighting, detailed skin texture, professional photography"]
    },
    {
      "id": 5,
      "type": "EmptyLatentImage",
      "pos": [450, 350],
      "size": [315, 106],
      "flags": {},
      "order": 3,
      "mode": 0,
      "outputs": [{"name": "LATENT", "type": "LATENT", "links": [5], "slot_index": 0}],
      "properties": {"Node name for S&R": "EmptyLatentImage"},
      "widgets_values": [1024, 1024, 1]
    },
    {
      "id": 6,
      "type": "BasicScheduler",
      "pos": [850, 350],
      "size": [315, 106],
      "flags": {},
      "order": 5,
      "mode": 0,
      "inputs": [{"name": "model", "type": "MODEL", "link": 1}],
      "outputs": [{"name": "SIGMAS", "type": "SIGMAS", "links": [6], "slot_index": 0}],
      "properties": {"Node name for S&R": "BasicScheduler"},
      "widgets_values": ["normal", 28, 1.0]
    },
    {
      "id": 7,
      "type": "KSamplerSelect",
      "pos": [850, 500],
      "size": [315, 58],
      "flags": {},
      "order": 6,
      "mode": 0,
      "outputs": [{"name": "SAMPLER", "type": "SAMPLER", "links": [7], "slot_index": 0}],
      "properties": {"Node name for S&R": "KSamplerSelect"},
      "widgets_values": ["euler"]
    },
    {
      "id": 8,
      "type": "RandomNoise",
      "pos": [850, 600],
      "size": [315, 82],
      "flags": {},
      "order": 7,
      "mode": 0,
      "outputs": [{"name": "NOISE", "type": "NOISE", "links": [8], "slot_index": 0}],
      "properties": {"Node name for S&R": "RandomNoise"},
      "widgets_values": [42]
    },
    {
      "id": 9,
      "type": "BasicGuider",
      "pos": [850, 100],
      "size": [315, 82],
      "flags": {},
      "order": 8,
      "mode": 0,
      "inputs": [
        {"name": "model", "type": "MODEL", "link": 1},
        {"name": "conditioning", "type": "CONDITIONING", "link": 4}
      ],
      "outputs": [{"name": "GUIDER", "type": "GUIDER", "links": [9], "slot_index": 0}],
      "properties": {"Node name for S&R": "BasicGuider"}
    },
    {
      "id": 10,
      "type": "SamplerCustomAdvanced",
      "pos": [1250, 100],
      "size": [315, 166],
      "flags": {},
      "order": 9,
      "mode": 0,
      "inputs": [
        {"name": "noise", "type": "NOISE", "link": 8},
        {"name": "guider", "type": "GUIDER", "link": 9},
        {"name": "sampler", "type": "SAMPLER", "link": 7},
        {"name": "sigmas", "type": "SIGMAS", "link": 6},
        {"name": "latent_image", "type": "LATENT", "link": 5}
      ],
      "outputs": [
        {"name": "output", "type": "LATENT", "links": [10], "slot_index": 0},
        {"name": "denoised_output", "type": "LATENT", "links": null}
      ],
      "properties": {"Node name for S&R": "SamplerCustomAdvanced"}
    },
    {
      "id": 11,
      "type": "VAEDecode",
      "pos": [1250, 320],
      "size": [210, 46],
      "flags": {},
      "order": 10,
      "mode": 0,
      "inputs": [
        {"name": "samples", "type": "LATENT", "link": 10},
        {"name": "vae", "type": "VAE", "link": 3}
      ],
      "outputs": [{"name": "IMAGE", "type": "IMAGE", "links": [11], "slot_index": 0}],
      "properties": {"Node name for S&R": "VAEDecode"}
    },
    {
      "id": 12,
      "type": "SaveImage",
      "pos": [1250, 420],
      "size": [315, 270],
      "flags": {},
      "order": 11,
      "mode": 0,
      "inputs": [{"name": "images", "type": "IMAGE", "link": 11}],
      "properties": {"Node name for S&R": "SaveImage"},
      "widgets_values": ["flux2_output"]
    }
  ],
  "links": [
    [1, 1, 0, 9, 0, "MODEL"],
    [2, 2, 0, 4, 0, "CLIP"],
    [3, 3, 0, 11, 1, "VAE"],
    [4, 4, 0, 9, 1, "CONDITIONING"],
    [5, 5, 0, 10, 4, "LATENT"],
    [6, 6, 0, 10, 3, "SIGMAS"],
    [7, 7, 0, 10, 2, "SAMPLER"],
    [8, 8, 0, 10, 0, "NOISE"],
    [9, 9, 0, 10, 1, "GUIDER"],
    [10, 10, 0, 11, 0, "LATENT"],
    [11, 11, 0, 12, 0, "IMAGE"]
  ],
  "groups": [],
  "config": {},
  "extra": {"ds": {"scale": 0.8, "offset": [0, 0]}},
  "version": 0.4
}
WORKFLOW_EOF

    sudo chown -R ubuntu:ubuntu "${COMFYUI_DIR}/user" 2>/dev/null || true
    echo "✓ Default workflow создан"
}

# Подготовка директорий
provisioning_prepare_dirs() {
    echo "Подготавливаем необходимые директории..."
    
    # Директория для пользовательских данных ComfyUI
    sudo -u ubuntu mkdir -p "${COMFYUI_DIR}/user/default/workflows"
    sudo chown -R ubuntu:ubuntu "${COMFYUI_DIR}/user"
    
    # Директория для логов
    mkdir -p "$LOG_DIR"
    chown ubuntu:ubuntu "$LOG_DIR"
}

# Настройка Supervisor
provisioning_setup_supervisor() {
    echo "Настраиваем Supervisor для ComfyUI..."
    
    # Генерируем конфиг Supervisor
    cat > "$SUPERVISOR_CONF" <<EOL
[program:comfyui]
directory=${COMFYUI_DIR}
command=${VENV_DIR}/bin/python main.py --listen 0.0.0.0 --port ${COMFYUI_PORT} --enable-cors-header
autostart=true
autorestart=true
startsecs=15
startretries=3
stdout_logfile=${LOG_DIR}/comfyui.log
stderr_logfile=${LOG_DIR}/comfyui.err
stopsignal=TERM
user=ubuntu
environment=HOME="${UBUNTU_HOME}",PYTHONUNBUFFERED="1"
EOL

    # Обновляем Supervisor
    supervisorctl reread
    supervisorctl update

    if supervisorctl status comfyui | grep -q "RUNNING"; then
        echo "ComfyUI уже запущен Supervisor-ом."
    else
        echo "Запускаем ComfyUI..."
        supervisorctl start comfyui
    fi

    # Логируем параметры запуска
    echo "----------------------------------------" | tee -a ${LOG_DIR}/startup_params.log
    echo "ComfyUI startup parameters:" | tee -a ${LOG_DIR}/startup_params.log
    echo "Port: ${COMFYUI_PORT}" | tee -a ${LOG_DIR}/startup_params.log
    echo "Directory: ${COMFYUI_DIR}" | tee -a ${LOG_DIR}/startup_params.log
    ps -ef | grep "main.py" | grep -v grep | tee -a ${LOG_DIR}/startup_params.log
    echo "----------------------------------------" | tee -a ${LOG_DIR}/startup_params.log
}

# =========================================
# Основной процесс
# =========================================
provisioning_start() {
    provisioning_print_header
    provisioning_create_ubuntu_user
    provisioning_get_apt_packages
    provisioning_install_python
    provisioning_setup_venv
    provisioning_clone_comfyui
    provisioning_get_custom_nodes
    provisioning_create_model_dirs
    provisioning_get_flux2_models
    provisioning_prepare_dirs
    provisioning_create_default_workflow
    provisioning_setup_supervisor
    provisioning_print_end
}

# =========================================
# Запуск provisioning
# =========================================
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi
