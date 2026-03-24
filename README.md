# Mac Restore Tool — Apple Silicon

Script de automatización para restaurar múltiples Macs Apple Silicon usando Apple Configurator 2.

## Prerequisitos

1. **Apple Configurator 2** instalado desde la App Store
2. Instalar las herramientas de línea de comando:
   - Abre Apple Configurator 2
   - Menú `Apple Configurator 2` → `Instalar Herramientas de Automatización`
3. El archivo **IPSW** del sistema operativo que quieres instalar
   - Descarga desde: https://ipsw.me → selecciona el modelo y versión

## Uso

```bash
# Dar permisos de ejecución
chmod +x restore.sh

# Ejecutar (busca IPSW en ~/Downloads por defecto)
./restore.sh

# O especificar carpeta de IPSW
IPSW_DIR=/Volumes/Storage/IPSWs ./restore.sh

# Cambiar el límite de restores paralelos (default: 4)
PARALLEL_MAX=6 ./restore.sh
```

## Modos de operación

| Modo | Descripción |
|------|-------------|
| **Restaurar todos** | Detecta todos los Macs en DFU conectados y los restaura en paralelo |
| **Monitor** | Queda en espera y restaura automáticamente cada Mac que se conecte en DFU |

## Cómo poner un Mac Apple Silicon en DFU Mode

1. Apaga el Mac completamente
2. Conecta el cable USB-C al puerto más cercano a la fuente de alimentación
3. Mantén presionado el **botón de encendido** ~10 segundos (la pantalla debe quedar negra, sin logo)
4. El Mac host detectará el dispositivo automáticamente

## Estructura de logs

```
~/mac-restore-logs/
├── session_20260324_143022.log     # Log de la sesión completa
├── device_ECID123_143025.log       # Log individual por dispositivo
└── device_ECID456_143026.log
```

## Notas

- El restore **borra todos los datos** del Mac destino
- Después del restore el Mac arranca en **Setup Assistant** (configuración inicial)
- Cada restore tarda ~10-15 minutos dependiendo del tamaño del IPSW
- Se pueden restaurar varios Macs en paralelo usando un hub USB-C
