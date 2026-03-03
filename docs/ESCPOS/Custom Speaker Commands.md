# Printer Speaker Command Sequences

## Speaker Configuration

**config.common.speaker**  
Red markings:  
- `01` → speaker **ON**  
- `00` → speaker **OFF**

**config.common.speakerVolume** : set 1–8  
Blue markings: Volume level  
- `01` – `08` (select desired value)

### Speaker command template

```
1b 1c 26 20 56 31 20 64 6f 20 22 75 6e 6c 6f 63 6b 5f 70 61 72 61 22 0d 0a
1b 1c 26 20 56 31 20 73 65 74 6b 65 79 0d 0a 00 ee 01 04 01/00  00 00 00     ← 01 = on / 00 = off
1b 1c 26 20 56 31 20 73 65 74 6b 65 79 0d 0a 00 ef 01 01 01(02....08)       ← volume 01–08
1b 1c 26 20 56 31 20 73 65 74 6b 65 79 0d 0a 00 92 01 01 00
1b 1c 26 20 56 31 20 64 6f 20 22 73 61 76 65 5f 70 61 72 61 6D 5f 7a 6f 6e 65 22 0d 0a
1b 1c 26 20 56 31 20 64 6f 20 22 72 65 73 65 74 5f 70 72 69 6e 74 65 72 22 0d 0a     
```
