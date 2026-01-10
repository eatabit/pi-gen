# 2.10 Status Commands

This section describes commands for transmitting printer status, paper sensor status, drawer kick status, and enabling automatic status notification (ASB - Auto Status Back).

## ESC v

**[Name]**  
Transmit paper sensor status

**[Format]**  
ASCII: ESC v  
Hex: 1B 76  
Decimal: 27 118

**[Range]**  
None

**[Description]**  
Transmits the current status of the paper sensors.  
The printer sends 1 byte of data:  
- Bit 2, 3: Roll paper sensor status near end (0 = paper adequate, 1 = near end)  
- Bit 6, 7: Roll paper sensor status end (0 = paper present, 1 = paper not present)  
Other bits are typically fixed or reserved (e.g., 0).

**[Notes]**  
- This command is executed upon reception.  
- Transmitted even if the printer is offline or in error state.  
- Useful for checking paper low/out conditions.

**[Default]**  
None

## GS r n

**[Name]**  
Transmit status

**[Format]**  
ASCII: GS r n  
Hex: 1D 72 n  
Decimal: 29 114 n

**[Range]**  
n = 1, 49 (for paper sensor status)  
n = 2, 50 (for drawer kick status)

**[Description]**  
Transmits the current status according to n:  
- n = 1 or 49: Paper sensor status (same as ESC v, 1 byte)  
- n = 2 or 50: Drawer kick connector pin status (1 byte)

**[Notes]**  
- This is a non-real-time command (processed after previous data).  
- Returns 1 byte of status data.

## DLE EOT n [a]

**[Name]**  
Transmit real-time status

**[Format]**  
ASCII: DLE EOT n [a]  
Hex: 10 04 n [a]  
Decimal: 16 4 n [a]

**[Range]**  
n = 1, 2, 3, 4 (basic status, offline cause, error cause, paper sensor)  
a (optional, depending on printer model)

**[Description]**  
Real-time command (processed immediately):  
- n=1: Printer status (online/offline, drawer kick, etc.)  
- n=2: Offline cause (cover open, paper feed button, mechanical error, auto-cutter error)  
- n=3: Error cause (no error, cover open, paper end, cutter error, etc.)  
- n=4: Paper sensor status (near-end and end)

**[Notes]**  
- Real-time execution, even in receive buffer full or error state.  
- Returns 1 byte per request.  
- Highly recommended for reliable status polling.

## GS a n

**[Name]**  
Enable/disable Automatic Status Back (ASB)

**[Format]**  
ASCII: GS a n  
Hex: 1D 61 n  
Decimal: 29 97 n

**[Range]**  
n = 0 to 255 (bitmask)

**[Description]**  
Enables or disables automatic transmission of status when printer state changes.  
Each bit enables/disables notification for:  
- Bit 0: Drawer kick pin status  
- Bit 1: Online/offline status  
- Bit 2: Paper sensor status (near end)  
- Bit 3: Paper sensor status (end)  
- Bit 4: Error status  
- etc. (up to bit 7)

**[Notes]**  
- When enabled, printer sends 4 bytes of status automatically on change.  
- Very useful for real-time monitoring without polling.

## GS l n (or GS i n in some references)

**[Name]**  
Transmit printer ID / maintenance counter (varies by model)

**[Format]**  
ASCII: GS l n  
Hex: 1D 6C n  
Decimal: 29 108 n

**[Range]**  
n depends on model (often for counter or ID)

**[Description]**  
Transmits printer identification, maintenance counter, or similar info.

**[Notes]**  
- Model-specific; check exact behavior for TP80N.