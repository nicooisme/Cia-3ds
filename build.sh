#!/usr/bin/env bash
# build.sh - compila o projeto 3DS e gera .3dsx E .cia dentro do Docker.
# Trata problemas de permissao automaticamente.

set -uo pipefail

say()  { echo -e "\n>>> $1"; }
fail() { echo -e "\n❌ ERRO: $1\n"; exit 1; }
ok()   { echo -e "✅ $1"; }

# ---------------------------------------------------------------------------
# 1) localizar a pasta do projeto (build3ds)
# ---------------------------------------------------------------------------
say "Procurando a pasta do projeto..."
PROJECT_DIR=$(find /workspaces -maxdepth 4 -type d -name build3ds 2>/dev/null | head -1)
[ -z "$PROJECT_DIR" ] && PROJECT_DIR=$(pwd)
cd "$PROJECT_DIR" || fail "Nao consegui entrar em $PROJECT_DIR"
[ -f Makefile ] || fail "Makefile nao encontrado em $PROJECT_DIR"
ok "Projeto em: $PROJECT_DIR"

# ---------------------------------------------------------------------------
# 2) checar Docker (e usar sudo se precisar)
# ---------------------------------------------------------------------------
say "Checando Docker..."
command -v docker >/dev/null 2>&1 || fail "Docker nao encontrado."
DOCKER="docker"
if ! docker info >/dev/null 2>&1; then
    say "Sem acesso direto ao Docker, tentando com sudo..."
    DOCKER="sudo docker"
fi
$DOCKER image inspect devkitpro/devkitarm >/dev/null 2>&1 || {
    say "Baixando imagem devkitpro/devkitarm..."
    $DOCKER pull devkitpro/devkitarm || fail "Nao consegui baixar a imagem."
}
ok "Docker disponivel."

# ---------------------------------------------------------------------------
# 3) corrigir bug conhecido do tex3ds no Makefile
# ---------------------------------------------------------------------------
say "Aplicando correcoes conhecidas no Makefile..."
python3 - << 'PYEOF'
path = "Makefile"
with open(path) as f:
    content = f.read()
bad = "tex3ds -i $(f) -h $(GFXBUILD)/$(basename $(notdir $(f))).h -o $(GFXBUILD)/$(basename $(notdir $(f))).t3x;"
fixed = "tex3ds -H $(GFXBUILD)/$(basename $(notdir $(f))).h -o $(GFXBUILD)/$(basename $(notdir $(f))).t3x $(f);"
if bad in content:
    open(path, "w").write(content.replace(bad, fixed))
    print("Makefile: bug do tex3ds corrigido.")
else:
    print("Makefile: nada a corrigir.")
PYEOF

# ---------------------------------------------------------------------------
# 4) tudo dentro de UM container rodando como root (--user root resolve
#    os 'permission denied' do pacman e da escrita em /usr/local/bin)
# ---------------------------------------------------------------------------
say "Compilando e gerando .cia (pode levar 1-2 minutos)..."
LOG="build.log"

$DOCKER run --rm --user root -v "$(pwd):/project" -w /project devkitpro/devkitarm bash -c '
set -e

echo ">>> Limpando build anterior..."
make clean >/dev/null 2>&1 || true
rm -rf romfs build *.elf *.3dsx *.smdh *.cia *.3ds *.bnr *.icn 2>/dev/null || true

echo ">>> Instalando makerom (general-tools)..."
dkp-pacman -Sy --noconfirm general-tools >/dev/null 2>&1 || echo "(general-tools ja instalado ou indisponivel)"

echo ">>> Obtendo bannertool..."
if ! command -v bannertool >/dev/null 2>&1; then
    curl -fsSL -o /usr/local/bin/bannertool \
        https://github.com/Steveice10/bannertool/releases/latest/download/bannertool.elf \
        && chmod +x /usr/local/bin/bannertool \
        || echo "AVISO: nao consegui baixar o bannertool."
fi

echo ">>> Gerando banner e icone..."
bannertool makebanner -i banner_src.png -a silence.wav -o banner.bnr
bannertool makesmdh -s "Hakuchou no Tenshi" -l "Hakuchou no Tenshi" -p "autor" -i icon.png -o icon.icn

echo ">>> make (.3dsx)..."
make

echo ">>> make cia..."
make cia

# garante que os arquivos gerados pertencam ao usuario do host, nao a root
chown -R "$(stat -c %u:%g /project)" /project 2>/dev/null || true
' 2>&1 | tee "$LOG"

BUILD_EXIT=${PIPESTATUS[0]}

# ---------------------------------------------------------------------------
# 5) diagnostico
# ---------------------------------------------------------------------------
say "Resultado:"
if [ "$BUILD_EXIT" -ne 0 ] || grep -qiE "error|no such file|undefined reference|fatal error|permission denied" "$LOG"; then
    echo ""
    echo "❌ Houve problemas. Linhas relevantes:"
    echo "------------------------------------------------------------"
    grep -iE "error|no such file|undefined reference|fatal error|permission denied" "$LOG" | tail -30
    echo "------------------------------------------------------------"
    echo "Log completo: $PROJECT_DIR/build.log"
    exit 1
fi

if [ -f "hakucho-no-tenshi.cia" ]; then
    SIZE=$(du -h "hakucho-no-tenshi.cia" | cut -f1)
    ok "Build concluido! hakucho-no-tenshi.cia gerado ($SIZE)."
    [ -f "hakucho-no-tenshi.3dsx" ] && echo "   (tambem foi gerado o .3dsx)"
    echo ""
    echo "Instale no 3DS com CFW: copie o .cia pro SD e use o FBI > Install."
else
    fail "Terminou sem erro aparente, mas o .cia nao foi criado. Cola o build.log aqui."
fi
