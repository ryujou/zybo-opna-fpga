#include "usb_ch9.h"

#include <string.h>

#define USB_LE16(value) ((u16)(value))

#define USB_ENDPOINT0_MAXP 0x40
#define USB_BULKIN_EP 1
#define USB_BULKOUT_EP 1
#define USB_DEVICE_DESC 0x01
#define USB_CONFIG_DESC 0x02
#define USB_STRING_DESC 0x03
#define USB_INTERFACE_CFG_DESC 0x04
#define USB_ENDPOINT_CFG_DESC 0x05

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u16 bcdUSB;
	u8 bDeviceClass;
	u8 bDeviceSubClass;
	u8 bDeviceProtocol;
	u8 bMaxPacketSize0;
	u16 idVendor;
	u16 idProduct;
	u16 bcdDevice;
	u8 iManufacturer;
	u8 iProduct;
	u8 iSerialNumber;
	u8 bNumConfigurations;
#ifdef __ICCARM__
} USB_STD_DEV_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_DEV_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u16 wTotalLength;
	u8 bNumInterfaces;
	u8 bConfigurationValue;
	u8 iConfiguration;
	u8 bmAttributes;
	u8 bMaxPower;
#ifdef __ICCARM__
} USB_STD_CFG_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_CFG_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u8 bInterfaceNumber;
	u8 bAlternateSetting;
	u8 bNumEndPoints;
	u8 bInterfaceClass;
	u8 bInterfaceSubClass;
	u8 bInterfaceProtocol;
	u8 iInterface;
#ifdef __ICCARM__
} USB_STD_IF_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_IF_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u8 bEndpointAddress;
	u8 bmAttributes;
	u16 wMaxPacketSize;
	u8 bInterval;
#ifdef __ICCARM__
} USB_STD_EP_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_EP_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	u8 bLength;
	u8 bDescriptorType;
	u16 wLANGID[1];
#ifdef __ICCARM__
} USB_STD_STRING_DESC;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_STD_STRING_DESC;
#endif

#ifdef __ICCARM__
#pragma pack(push, 1)
#endif
typedef struct {
	USB_STD_CFG_DESC stdCfg;
	USB_STD_IF_DESC ifCfg;
	USB_STD_EP_DESC epCfg1;
	USB_STD_EP_DESC epCfg2;
#ifdef __ICCARM__
} USB_CONFIG;
#pragma pack(pop)
#else
} __attribute__((__packed__)) USB_CONFIG;
#endif

u32 XUsbPs_Ch9SetupDevDescReply(u8 *BufPtr, u32 BufLen)
{
	USB_STD_DEV_DESC deviceDesc = {
		sizeof(USB_STD_DEV_DESC),
		USB_DEVICE_DESC,
		USB_LE16(0x0200),
		0x00,
		0x00,
		0x00,
		USB_ENDPOINT0_MAXP,
		USB_LE16(0xCAFE),
		USB_LE16(0x4012),
		USB_LE16(0x0100),
		0x01,
		0x02,
		0x03,
		0x01
	};

	if ((BufPtr == NULL) || (BufLen < sizeof(USB_STD_DEV_DESC))) {
		return 0;
	}

	memcpy(BufPtr, &deviceDesc, sizeof(USB_STD_DEV_DESC));
	return sizeof(USB_STD_DEV_DESC);
}

u32 XUsbPs_Ch9SetupCfgDescReply(u8 *BufPtr, u32 BufLen)
{
	USB_CONFIG config = {
		{
			sizeof(USB_STD_CFG_DESC),
			USB_CONFIG_DESC,
			USB_LE16(sizeof(USB_CONFIG)),
			0x01,
			0x01,
			0x04,
			0xC0,
			0x00,
		},
		{
			sizeof(USB_STD_IF_DESC),
			USB_INTERFACE_CFG_DESC,
			0x00,
			0x00,
			0x02,
			0xFF,
			0x00,
			0x00,
			0x05,
		},
		{
			sizeof(USB_STD_EP_DESC),
			USB_ENDPOINT_CFG_DESC,
			0x00 | USB_BULKOUT_EP,
			0x02,
			USB_LE16(0x40),
			0x00,
		},
		{
			sizeof(USB_STD_EP_DESC),
			USB_ENDPOINT_CFG_DESC,
			0x80 | USB_BULKIN_EP,
			0x02,
			USB_LE16(0x40),
			0x00,
		},
	};

	if ((BufPtr == NULL) || (BufLen < sizeof(USB_CONFIG))) {
		return 0;
	}

	memcpy(BufPtr, &config, sizeof(USB_CONFIG));
	return sizeof(USB_CONFIG);
}

u32 XUsbPs_Ch9SetupStrDescReply(u8 *BufPtr, u32 BufLen, u8 Index)
{
	u32 i;
	u32 StringLen;
	u32 DescLen;
	u8 TmpBuf[128];
	USB_STD_STRING_DESC *StringDesc;
	static const char *StringList[] = {
		"UNUSED",
		"Ryujou",
#ifdef OPNA_DUAL_MODE
        "Zybo PC98 OPNA",
#else
		"Zybo OPNA USB Interface",
#endif
		"ZOPNAUSB0001",
		"Default Configuration",
		"OPNA Data Interface",
	};
	const char *String;

	if ((BufPtr == NULL) || (Index >= (sizeof(StringList) / sizeof(char *)))) {
		return 0;
	}

	String = StringList[Index];
	StringLen = (u32)strlen(String);
	StringDesc = (USB_STD_STRING_DESC *)TmpBuf;

	if (Index == 0) {
		StringDesc->bLength = 4;
		StringDesc->bDescriptorType = USB_STRING_DESC;
		StringDesc->wLANGID[0] = USB_LE16(0x0409);
	} else {
		StringDesc->bLength = (u8)(StringLen * 2 + 2);
		StringDesc->bDescriptorType = USB_STRING_DESC;
		for (i = 0; i < StringLen; ++i) {
			StringDesc->wLANGID[i] = USB_LE16((u16)String[i]);
		}
	}

	DescLen = StringDesc->bLength;
	if (DescLen > BufLen) {
		return 0;
	}

	memcpy(BufPtr, StringDesc, DescLen);
	return DescLen;
}
