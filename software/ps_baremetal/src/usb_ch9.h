#ifndef USB_CH9_H_
#define USB_CH9_H_

#ifdef __cplusplus
extern "C" {
#endif

#include "xstatus.h"
#include "xusbps.h"
#include "xusbps_hw.h"

#define USB_ALIGN_CACHELINE __attribute__ ((aligned (32)))

typedef struct {
	u8 CurrentConfig;
} UsbCh9Local;

int XUsbPs_Ch9HandleSetupPacket(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData);
u32 XUsbPs_Ch9SetupDevDescReply(u8 *BufPtr, u32 BufLen);
u32 XUsbPs_Ch9SetupCfgDescReply(u8 *BufPtr, u32 BufLen);
u32 XUsbPs_Ch9SetupStrDescReply(u8 *BufPtr, u32 BufLen, u8 Index);
void XUsbPs_SetConfiguration(XUsbPs *InstancePtr, int ConfigIdx);
void XUsbPs_SetConfigurationApp(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData);
void XUsbPs_SetInterfaceHandler(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData);
int usb_ch9_is_configured(void);
void usb_ch9_reset_configured(void);

#ifdef __cplusplus
}
#endif

#endif
