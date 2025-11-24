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

# Definir cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Funções auxiliares para output colorido
print_header() {
    echo -e "${BOLD}${CYAN}$1${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗ ERRO:${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠ AVISO:${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_step() {
    echo -e "\n${BOLD}${BLUE}[$1]${NC} $2"
    sleep 0.5
}

# Banner inicial
clear
echo -e "${CYAN}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${CYAN}║${NC}${BOLD}         APLICANDO FIX PARA KIT X99 no LINUX         ${NC}${CYAN}║${NC}"
echo -e "${CYAN}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
sleep 1

# Verificar se está rodando como root ou com sudo
if [ "$EUID" -ne 0 ] && ! sudo -n true 2>/dev/null; then
    print_error "Este script precisa de privilégios sudo."
    exit 1
fi

# Validar hardware (CPU Intel e idealmente Xeon)
print_step "0/8" "Validando hardware..."

if [ ! -f /proc/cpuinfo ]; then
    print_error "/proc/cpuinfo não encontrado."
    exit 1
fi

CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo | cut -d':' -f2 | xargs)

if [ "$CPU_VENDOR" != "GenuineIntel" ]; then
    print_warning "CPU não é Intel (detectado: $CPU_VENDOR)"
    print_info "Este script é otimizado para processadores Intel Xeon em chipset X99."
    echo -ne "${YELLOW}Deseja continuar mesmo assim? (s/n):${NC} "
    read -r CONTINUE
    if [ "$CONTINUE" != "s" ] && [ "$CONTINUE" != "S" ]; then
        print_info "Operação cancelada pelo usuário."
        exit 0
    fi
else
    print_info "CPU detectada: ${BOLD}$CPU_MODEL${NC}"
    sleep 0.5
    if echo "$CPU_MODEL" | grep -qi "xeon"; then
        print_success "Processador Xeon detectado (ideal para X99)"
    else
        print_warning "Processador não é Xeon. Este script é otimizado para Xeon E5 v3/v4."
        echo -ne "${YELLOW}Deseja continuar? (s/n):${NC} "
        read -r CONTINUE
        if [ "$CONTINUE" != "s" ] && [ "$CONTINUE" != "S" ]; then
            print_info "Operação cancelada pelo usuário."
            exit 0
        fi
    fi
fi

# Tentar detectar chipset (melhor esforço)
if command -v lspci &> /dev/null; then
    CHIPSET=$(lspci | grep -i "ISA bridge" | head -n1)
    if [ -n "$CHIPSET" ]; then
        print_info "Chipset: $CHIPSET"
        sleep 0.5
    fi
fi

# Detectar a distribuição
print_step "1/8" "Detectando sistema operacional..."

if [ -f /etc/os-release ]; then
    . /etc/os-release
    DISTRO=$ID
    print_success "Sistema detectado: ${BOLD}$NAME${NC}"
    sleep 0.5
else
    print_error "Não foi possível detectar a distribuição."
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
        print_warning "Distribuição '$DISTRO' não totalmente suportada."
        print_info "O script tentará usar comandos genéricos."
        PKG_UPDATE="echo 'Pulando atualização'"
        PKG_INSTALL="echo 'Instalação manual necessária para'"
        GRUB_UPDATE="grub-mkconfig -o /boot/grub/grub.cfg"
        sleep 1
        ;;
esac

# 2. Criar backup do GRUB
print_step "2/8" "Criando backup do GRUB..."

GRUB_FILE="/etc/default/grub"
if [ -f "$GRUB_FILE" ]; then
    BACKUP_FILE="${GRUB_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    sudo cp "$GRUB_FILE" "$BACKUP_FILE"
    print_success "Backup criado: ${CYAN}$BACKUP_FILE${NC}"
    sleep 0.5
else
    print_error "Arquivo GRUB não encontrado em $GRUB_FILE"
    exit 1
fi

# 3. Instalar intel-microcode e ferramentas
print_step "3/8" "Instalando pacotes necessários..."

print_info "Atualizando repositórios..."
sudo $PKG_UPDATE
echo ""
print_info "Instalando: $MICROCODE_PKG, $CPUFREQ_PKG"
sudo $PKG_INSTALL $MICROCODE_PKG $CPUFREQ_PKG
echo ""
print_success "Pacotes instalados com sucesso"
sleep 1

# 4. Configurar GRUB com parâmetros completos de estabilidade para X99
print_step "4/8" "Configurando GRUB com parâmetros otimizados para X99..."

# Parâmetros completos para kits X99
GRUB_PARAMS="quiet splash intel_idle.max_cstate=0 processor.max_cstate=1 idle=poll intel_iommu=on iommu=pt pcie_aspm=off nmi_watchdog=0 nowatchdog intel_pstate=disable clocksource=tsc tsc=reliable"

print_info "Aplicando parâmetros de kernel..."
sudo sed -i.bak "s/GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT=\"$GRUB_PARAMS\"/" "$GRUB_FILE"
sleep 0.5

print_info "Atualizando GRUB..."
if sudo $GRUB_UPDATE 2>&1 | grep -v "^$"; then
    echo ""
    print_success "GRUB atualizado com sucesso"
    sleep 1
else
    echo ""
    print_error "Falha ao atualizar GRUB"
    print_info "Restaurando backup..."
    sudo cp "$BACKUP_FILE" "$GRUB_FILE"
    print_warning "Backup restaurado. Verifique a configuração manualmente."
    exit 1
fi

# 5. Configurar governor=performance permanentemente
print_step "5/8" "Configurando governor para performance..."

case $DISTRO in
    ubuntu|debian|zorin)
        print_info "Configurando cpufrequtils..."
        sudo bash -c 'echo GOVERNOR="performance" > /etc/default/cpufrequtils'
        sudo systemctl enable cpufrequtils 2>/dev/null || true
        sudo systemctl start cpufrequtils 2>/dev/null || true
        print_success "cpufrequtils configurado"
        sleep 0.5
        ;;
    fedora|rhel|centos|rocky|almalinux)
        # No Fedora/RHEL, usar tuned ou configuração direta
        if command -v tuned-adm &> /dev/null; then
            print_info "Configurando tuned profile..."
            sudo tuned-adm profile throughput-performance
            print_success "Tuned profile aplicado"
            sleep 0.5
        fi
        ;;
esac

# 6. Criar serviço systemd para governor permanente
print_step "6/8" "Criando serviço systemd para governor..."

SYSTEMD_SERVICE="/etc/systemd/system/cpufreq-performance.service"
print_info "Criando arquivo de serviço..."
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

print_info "Habilitando serviço..."
sudo systemctl daemon-reload
sudo systemctl enable cpufreq-performance.service 2>&1 | grep -v "^$" || true
print_success "Serviço systemd criado e habilitado"
sleep 0.5

# 7. Ajustar governor imediatamente
print_step "7/8" "Aplicando governor performance agora..."

if [ -d /sys/devices/system/cpu/cpu0/cpufreq ]; then
    print_info "Configurando todos os cores da CPU..."
    for CPU in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if [ -f "$CPU" ]; then
            echo performance | sudo tee "$CPU" > /dev/null
        fi
    done
    print_success "Governor aplicado em todos os cores"
    sleep 0.5
else
    print_warning "cpufreq não disponível neste sistema."
fi

# 8. Desabilitar irqbalance se existir
print_step "8/8" "Verificando e desabilitando irqbalance..."

if systemctl list-unit-files 2>/dev/null | grep -q irqbalance; then
    print_info "irqbalance encontrado, desabilitando..."
    sudo systemctl disable irqbalance 2>/dev/null || true
    sudo systemctl stop irqbalance 2>/dev/null || true
    print_success "irqbalance desabilitado"
    sleep 0.5
else
    print_success "irqbalance não está instalado (OK)"
fi

# 9. Mostrar resultado final
print_step "9/9" "Verificando estado atual..."

echo -e "\n${CYAN}═══════════════════════════════════════════════════════${NC}"
print_info "Parâmetros do kernel ativos:"
echo -e "${YELLOW}$(cat /proc/cmdline)${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"

if [ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]; then
    print_info "Governor atual:"
    echo -e "${GREEN}$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)${NC}"
    echo -e "${CYAN}═══════════════════════════════════════════════════════${NC}"
fi

echo ""
echo -e "${GREEN}${BOLD}✓ Concluído com sucesso!${NC}"
echo ""
print_warning "IMPORTANTE: Reinicie o sistema para aplicar todas as mudanças."
echo ""
echo -ne "${YELLOW}${BOLD}Deseja reiniciar automaticamente agora? (s/n):${NC} "
read -r RES

if [ "$RES" = "s" ] || [ "$RES" = "S" ]; then
    echo ""
    for i in 3 2 1; do
        echo -e "${RED}${BOLD}Reiniciando em $i segundos...${NC}"
        sleep 1
    done
    sudo reboot
else
    echo ""
    print_info "Lembre-se de reiniciar o sistema manualmente!"
    echo ""
fi
