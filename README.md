# rclone-mount-ramfs-all

Script Bash per montare un remote `rclone` come filesystem locale tramite `rclone mount`, allocando **sia il mountpoint locale che la VFS cache interamente in RAM** dentro un unico `tmpfs`.

Questa versione è pensata per massimizzare l'isolamento della sessione: tutto vive in RAM e scompare allo smontaggio. Il remote viene esposto come directory locale FUSE, mentre la cache VFS viene conservata nello stesso albero tmpfs. `rclone mount` supporta nativamente il mount su una directory locale e la VFS cache configurata con `--cache-dir`, `--vfs-cache-mode full`, `--vfs-cache-max-size` e opzioni correlate. [web:16]

## Caratteristiche

- Selezione interattiva del remote configurato in rclone. [web:16]
- Calcolo dinamico della RAM disponibile usando `MemAvailable`. [web:352]
- Creazione di un unico `tmpfs` in RAM per contenere:
  - il mountpoint locale FUSE;
  - la directory di cache VFS. [web:16]
- Apertura automatica del mount in Nemo.
- Cleanup completo con `Ctrl+C`:
  - chiusura Nemo;
  - unmount FUSE;
  - stop di rclone;
  - unmount del `tmpfs`.

## Architettura

Struttura tipica:

```text
/tmp/rclone-ram-<remote>-<pid>/
├── mount/    <- mountpoint rclone FUSE
└── cache/    <- VFS cache in RAM
```

Il mountpoint è il punto in cui `rclone mount` espone il contenuto del backend remoto, mentre la cache contiene i dati locali usati da rclone per letture/scritture efficienti. La documentazione di `rclone mount` indica che il mountpoint deve esistere ed essere vuoto, e che la VFS cache viene gestita separatamente nella directory impostata con `--cache-dir`. [web:16]

## Vantaggi

- Tutto è confinato in RAM, quindi la sessione è completamente temporanea.
- Nessuna scrittura di cache su SSD/HDD locali.
- Struttura semplice da smontare e ripulire.

## Svantaggi

- Il mountpoint non è “comodo” nella home dell’utente.
- La parte realmente critica per le prestazioni è la VFS cache; avere anche il mountpoint sotto tmpfs non porta in genere un vantaggio sostanziale rispetto ad averlo fuori dal tmpfs. [web:16]
- La sessione è completamente effimera.

## Requisiti

Pacchetti richiesti su Debian/Ubuntu/Linux Mint:

```bash
sudo apt update
sudo apt install rclone nemo fuse3 fuse libfuse2 coreutils netcat-openbsd psmisc lsof
```

Note:
- serve `rclone`;
- serve Nemo solo se vuoi l’apertura automatica nel file manager;
- serve `fusermount3` oppure `fusermount` per lo smontaggio FUSE. [web:16]

## Uso

```bash
chmod +x rclone-mount-ramfs-all.sh
./rclone-mount-ramfs-all.sh
```

Flusso:
1. scegli il remote;
2. scegli la percentuale di `MemAvailable` da allocare al `tmpfs`;
3. lo script crea il `tmpfs`;
4. rclone monta il remote su `mount/`;
5. Nemo si apre sul mountpoint locale;
6. `Ctrl+C` chiude e pulisce tutto.

## Parametri rclone usati

La versione usa tipicamente:

```bash
rclone mount REMOTE: MOUNTPOINT \
  --cache-dir CACHE_DIR \
  --vfs-cache-mode full \
  --vfs-cache-max-size ... \
  --vfs-cache-min-free-space ... \
  --vfs-cache-max-age 1h \
  --dir-cache-time 10m \
  --buffer-size 16M \
  --vfs-read-chunk-size 32M \
  --vfs-read-chunk-size-limit 256M
```

`--vfs-cache-mode full` è la scelta più adatta per workload reali che richiedono seek, accessi casuali e scritture/letture complete su file montati. [web:16][web:347]

## Prestazioni

Questa variante offre ottime prestazioni perché la cache è in RAM. Tuttavia, il vero beneficio arriva soprattutto dal fatto che **la VFS cache** si trova in memoria; il mountpoint in tmpfs è più una scelta architetturale che un reale acceleratore separato. [web:16][web:346]

## Quando usarla

Usa questa versione se vuoi:
- una sessione completamente volatile;
- nessuna traccia persistente locale;
- tutto confinato in RAM sotto un unico albero temporaneo.

## Limiti

- Consumo RAM più difficile da osservare in modo intuitivo per utenti non tecnici.
- Layout meno comodo da navigare rispetto a un mountpoint in home.
- Poco vantaggio pratico rispetto alla variante con mountpoint in home e cache in RAM, a parità di impostazioni di cache. [web:16]

## Licenza

Aggiungi la tua licenza preferita, ad esempio MIT.
