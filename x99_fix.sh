#!/bin/bash

################################################################################
# Script: x99_fix.sh
# Versão: 1.0
# Autor: Daniel Almeida
# Github: https://github.com/dcalmeida149/x99_fix
#
# Data: 23/11/2025
#
# Descrição:
#   Script de otimização e estabilização para kits X99 (chipsets chineses)
#   rodando em sistemas Linux. Aplica correções de microcode, parâmetros de
#   kernel otimizados, desabilita estados de energia problemáticos e configura
#   o CPU governor para máxima performance.
#
# O que o script faz:
#   - Detecta automaticamente a distribuição Linux (Ubuntu, Debian, Zorin OS,
#     Fedora, RHEL, CentOS, Rocky, AlmaLinux)
#   - Cria backup automático das configurações do GRUB
#   - Instala intel-microcode/microcode_ctl para atualização de microcódigo
#   - Configura parâmetros otimizados do kernel para X99:
#     * Desabilita C-States problemáticos
#     * Configura IOMMU para modo passthrough
#     * Desabilita PCIe ASPM (gerenciamento de energia PCIe)
#     * Desabilita watchdog do kernel
#     * Configura TSC como clocksource confiável
#     * Desabilita intel_pstate
#   - Configura CPU governor para "performance"
#   - Desabilita irqbalance (se instalado)
#
# ANTES DE EXECUTAR - VALIDE:
#   1. Você está usando um processador Intel Xeon E5 v3/v4 em placa X99
#   2. Seu sistema é Ubuntu, Debian, Zorin OS, Fedora ou RHEL/derivados
#   3. Você tem privilégios sudo/root
#   4. Você tem backup do sistema (recomendado)
#   5. Você entende que o script modificará o GRUB e requer reinicialização
#
# COMPATIBILIDADE:
#   - Ubuntu / Debian / Zorin OS (testado)
#   - Fedora / RHEL / CentOS / Rocky / AlmaLinux (testado)
#   - Outras distros: suporte parcial
#
# USO:
#   chmod +x x99_fix.sh
#   ./x99_fix.sh
#
# NOTAS:
#   - Um backup do GRUB será criado automaticamente em /etc/default/grub.backup.*
#   - O sistema precisará ser reiniciado após a execução
#   - Em caso de problemas, restaure o backup do GRUB e execute update-grub
#
################################################################################

set -e  # Para o script em caso de erro

echo "---------------------------------------------"
echo "   APLICANDO FIX PARA KIT X99 no LINUX"
echo "---------------------------------------------"
sleep 2

# Verificar se está rodando como root ou com sudo
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    echo "ERRO: Este script precisa de privilégios sudo."
    exit 1
fi

# Validar hardware (CPU Intel e idealmente Xeon)
echo "[0/8] Validando hardware..."
if [ ! -f /proc/cpuinfo ]; then
    echo "ERRO: /proc/cpuinfo não encontrado."
    exit 1
fi

CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | xargs)

if [ "$CPU_VENDOR" != "GenuineIntel" ]; then
    echo "AVISO: CPU não é Intel (detectado: $CPU_VENDOR)"
    echo "Este script é otimizado para processadores Intel Xeon em chipset X99."
    read -r -p "Deseja continuar mesmo assim? (s/n): " CONTINUE
    if [ "$CONTINUE" != "s" ] && [ "$CONTINUE" != "S" ]; then
        echo "Operação cancelada pelo usuário."
        exit 0
    fi
else
    echo "CPU detectada: $CPU_MODEL"
    if echo "$CPU_MODEL" | grep -qi "xeon"; then
        echo "✓ Processador Xeon detectado (ideal para X99)"
    else
        echo "AVISO: Processador não é Xeon. Este script é otimizado para Xeon E5 v3/v4."
        read -r -p "Deseja continuar? (s/n): " CONTINUE
        if [ "$CONTINUE" != "s" ] && [ "$CONTINUE" != "S" ]; then
            echo "Operação cancelada pelo usuário."
            exit 0
        fi
    fi
fi

# Tentar detectar chipset (melhor esforço)
if command -v lspci &> /dev/null; then
    CHIPSET=$(lspci | grep -i "ISA bridge" | head -n1)
    if [ -n "$CHIPSET" ]; then
        echo "Chipset detectado: $CHIPSET"
    fi
fi

# Detectar a distribuição
echo "[1/8] Detectando sistema operacional..."
if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    echo "Sistema detectado: $NAME"
else
    echo "ERRO: Não foi possível detectar a distribuição."
    exit 1
fi

# Definir comandos específicos por distro
case $DISTRO in
    ubuntu|debian|zorin)
        PKG_UPDATE="apt update"
        PKG_INSTALL="apt install -y"
        MICROCODE_PKG="intel-microcode"
        CPUFREQ_PKG="cpufrequtils"
        GRUB_UPDATE="update-grub"
        ;;
    fedora|rhel|centos|rocky|almalinux)
        PKG_UPDATE="dnf check-update || true"
        PKG_INSTALL="dnf install -y"
        MICROCODE_PKG="microcode_ctl"
        CPUFREQ_PKG="kernel-tools"
        GRUB_UPDATE="grub2-mkconfig -o /boot/grub2/grub.cfg"
        ;;
    *)
        echo "AVISO: Distribuição '$DISTRO' não totalmente suportada."
        echo "O script tentará usar comandos genéricos."
        PKG_UPDATE="echo 'Pulando atualização'"
        PKG_INSTALL="echo 'Instalação manual necessária para'"
        GRUB_UPDATE="grub-mkconfig -o /boot/grub/grub.cfg"
        ;;
esac

# 2. Criar backup do GRUB
echo "[2/8] Criando backup do GRUB..."
GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ]; then
    BACKUP_FILE="${GRUB_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    sudo cp "$GRUB_FILE" "$BACKUP_FILE"
    echo "Backup criado: $BACKUP_FILE"
else
    echo "ERRO: Arquivo GRUB não encontrado em $GRUB_FILE"
    exit 1
fi

# 3. Instalar intel-microcode e ferramentas
echo "[3/8] Instalando pacotes necessários..."
sudo $PKG_UPDATE
sudo $PKG_INSTALL $MICROCODE_PKG $CPUFREQ_PKG

# 4. Configurar GRUB com parâmetros completos de estabilidade para X99
echo "[4/8] Configurando GRUB com parâmetros otimizados para X99..."

# Parâmetros completos para kits X99
GRUB_PARAMS="quiet splash intel_idle.max_cstate=0 processor.max_cstate=1 idle=poll intel_iommu=on iommu=pt pcie_aspm=off nmi_watchdog=0 nowatchdog intel_pstate=disable clocksource=tsc tsc=reliable"

sudo sed -i.bak "s/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"$GRUB_PARAMS\"/" "$GRUB_FILE"

echo "Atualizando GRUB..."
if sudo $GRUB_UPDATE; then
    echo "✓ GRUB atualizado com sucesso"
else
    echo "ERRO: Falha ao atualizar GRUB"
    echo "Restaurando backup..."
    sudo cp "$BACKUP_FILE" "$GRUB_FILE"
    echo "Backup restaurado. Verifique a configuração manualmente."
    exit 1
fi

# 5. Configurar governor=performance permanentemente
echo "[5/8] Configurando governor para performance..."

case $DISTRO in
    ubuntu|debian|zorin)
        sudo bash -c 'echo GOVERNOR="performance" > /etc/default/cpufrequtils'
        sudo systemctl enable cpufrequtils 2>/dev/null || true
        sudo systemctl start cpufrequtils 2>/dev/null || true
        ;;
    fedora|rhel|centos|rocky|almalinux)
        # No Fedora/RHEL, usar tuned ou configuração direta
        if command -v tuned-adm &> /dev/null; then
            sudo tuned-adm profile throughput-performance
        fi
        ;;
esac

# 6. Criar serviço systemd para governor permanente
echo "[6/8] Criando serviço systemd para governor..."

SYSTEMD_SERVICE="/etc/systemd/system/cpufreq-performance.service"
sudo tee "$SYSTEMD_SERVICE" > /dev/null <<EOF
[Unit]
Description=Set CPU Governor to Performance
After=multi-user.target

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'for cpu in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do [ -f \$cpu ] && echo performance > \$cpu; done'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable cpufreq-performance.service
echo "✓ Serviço systemd criado e habilitado"

# 7. Ajustar governor imediatamente
echo "[7/8] Aplicando governor performance agora..."
if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    for CPU in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [ -f "$CPU" ]; then
            echo performance | sudo tee "$CPU" > /dev/null
        fi
    done
    echo "Governor aplicado com sucesso."
else
    echo "AVISO: cpufreq não disponível neste sistema."
fi

# 8. Desabilitar irqbalance se existir
echo "[8/8] Verificando e desabilitando irqbalance..."
if systemctl list-unit-files 2>/dev/null | grep -q irqbalance; then
    echo "irqbalance encontrado, desabilitando..."
    sudo systemctl disable irqbalance 2>/dev/null || true
    sudo systemctl stop irqbalance 2>/dev/null || true
    echo "irqbalance desabilitado."
else
    echo "irqbalance não está instalado (OK)."
fi

# 9. Mostrar resultado final
echo "[9/9] Verificando estado atual:"
echo "---------------------------------------------"
echo "Parâmetros do kernel:"
cat /proc/cmdline
echo "---------------------------------------------"
if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    echo "Governor atual:"
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
    echo "---------------------------------------------"
fi

echo ""
echo "✓ Concluído com sucesso!"
echo ""
echo "IMPORTANTE: Reinicie o sistema para aplicar todas as mudanças."
read -r -p "Deseja reiniciar automaticamente agora? (s/n): " RES

if [ "$RES" = "s" ] || [ "$RES" = "S" ]; then
    echo "Reiniciando em 3 segundos..."
    sleep 3
    sudo reboot
else
    echo "Lembre-se de reiniciar o sistema manualmente!"
fi
