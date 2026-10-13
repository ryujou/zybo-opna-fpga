#include "usb_ch9.h"

#include <string.h>

#include "xil_cache.h"

#define XUSBPS_REQ_TYPE_MASK 0x60
#define XUSBPS_CMD_STDREQ 0x00
#define XUSBPS_CMD_VENDREQ 0x40
#define XUSBPS_REQ_REPLY_LEN 1024
#define XUSBPS_REQ_GET_STATUS 0x00
#define XUSBPS_REQ_CLEAR_FEATURE 0x01
#define XUSBPS_REQ_SET_FEATURE 0x03
#define XUSBPS_REQ_SET_ADDRESS 0x05
#define XUSBPS_REQ_GET_DESCRIPTOR 0x06
#define XUSBPS_REQ_GET_CONFIGURATION 0x08
#define XUSBPS_REQ_SET_CONFIGURATION 0x09
#define XUSBPS_REQ_GET_INTERFACE 0x0A
#define XUSBPS_REQ_SET_INTERFACE 0x0B
#define XUSBPS_STATUS_MASK 0x3
#define XUSBPS_STATUS_DEVICE 0x0
#define XUSBPS_STATUS_INTERFACE 0x1
#define XUSBPS_STATUS_ENDPOINT 0x2
#define XUSBPS_ENDPOINT_HALT 0x00
#define XUSBPS_TYPE_DEVICE_DESC 0x01
#define XUSBPS_TYPE_CONFIG_DESC 0x02
#define XUSBPS_TYPE_STRING_DESC 0x03
#define XUSBPS_TYPE_DEVICE_QUALIFIER 0x06
#define XUSBPS_TEST_MODE 0x02
#define USB_WCID_STRING_INDEX 0xEE
#define USB_WCID_VENDOR_CODE 0x20
#define USB_WCID_COMPAT_ID_INDEX 0x0004

static u8 Response USB_ALIGN_CACHELINE;
static volatile int g_configured = 0;

static void usb_ch9_flush_configured(void)
{
	Xil_DCacheFlushRange((INTPTR)&g_configured, sizeof(g_configured));
}

static void XUsbPs_StdDevReq(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData);
static int XUsbPs_HandleVendorReq(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData);

static const u8 kMsOsStringDescriptor[] USB_ALIGN_CACHELINE = {
	18,
	XUSBPS_TYPE_STRING_DESC,
	'M', 0,
	'S', 0,
	'F', 0,
	'T', 0,
	'1', 0,
	'0', 0,
	'0', 0,
	USB_WCID_VENDOR_CODE,
	0x00,
};

static const u8 kMsCompatIdDescriptor[] USB_ALIGN_CACHELINE = {
	0x28, 0x00, 0x00, 0x00,
	0x00, 0x01,
	0x04, 0x00,
	0x01,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00,
	0x01,
	'W', 'I', 'N', 'U', 'S', 'B', 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
	0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
};

int XUsbPs_Ch9HandleSetupPacket(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData)
{
	if ((SetupData->bmRequestType & XUSBPS_REQ_TYPE_MASK) == XUSBPS_CMD_STDREQ) {
		XUsbPs_StdDevReq(InstancePtr, SetupData);
		return XST_SUCCESS;
	}

	if ((SetupData->bmRequestType & XUSBPS_REQ_TYPE_MASK) == XUSBPS_CMD_VENDREQ) {
		return XUsbPs_HandleVendorReq(InstancePtr, SetupData);
	}

	XUsbPs_EpStall(InstancePtr, 0, XUSBPS_EP_DIRECTION_IN | XUSBPS_EP_DIRECTION_OUT);
	return XST_FAILURE;
}

static void XUsbPs_StdDevReq(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData)
{
	int Error = 0;
	int ReplyLen = 0;
	UsbCh9Local *UsbLocalPtr;
	static u8 Reply[XUSBPS_REQ_REPLY_LEN] USB_ALIGN_CACHELINE;

	if (SetupData->wLength > XUSBPS_REQ_REPLY_LEN) {
		XUsbPs_EpStall(InstancePtr, 0, XUSBPS_EP_DIRECTION_IN | XUSBPS_EP_DIRECTION_OUT);
		return;
	}

	UsbLocalPtr = (UsbCh9Local *)InstancePtr->UserDataPtr;

	switch (SetupData->bRequest) {
	case XUSBPS_REQ_GET_STATUS:
		switch (SetupData->bmRequestType & XUSBPS_STATUS_MASK) {
		case XUSBPS_STATUS_DEVICE:
			*((u16 *)&Reply[0]) = 0x1;
			break;
		case XUSBPS_STATUS_INTERFACE:
			*((u16 *)&Reply[0]) = 0x0;
			break;
		case XUSBPS_STATUS_ENDPOINT: {
			u32 Status;
			int EpNum = SetupData->wIndex;

			Status = XUsbPs_ReadReg(InstancePtr->Config.BaseAddress, XUSBPS_EPCRn_OFFSET(EpNum & 0xF));
			if (EpNum & 0x80) {
				*((u16 *)&Reply[0]) = (Status & XUSBPS_EPCR_TXS_MASK) ? 1 : 0;
			} else {
				*((u16 *)&Reply[0]) = (Status & XUSBPS_EPCR_RXS_MASK) ? 1 : 0;
			}
			break;
		}
		default:
			Error = 1;
			break;
		}
		if (!Error) {
			(void)XUsbPs_EpBufferSend(InstancePtr, 0, Reply, SetupData->wLength);
		}
		break;

	case XUSBPS_REQ_SET_ADDRESS:
		XUsbPs_SetDeviceAddress(InstancePtr, SetupData->wValue);
		(void)XUsbPs_EpBufferSend(InstancePtr, 0, NULL, 0);
		break;

	case XUSBPS_REQ_GET_INTERFACE:
		Response = (u8)InstancePtr->CurrentAltSetting;
		(void)XUsbPs_EpBufferSend(InstancePtr, 0, &Response, 1);
		break;

	case XUSBPS_REQ_GET_DESCRIPTOR:
		switch ((SetupData->wValue >> 8) & 0xFF) {
		case XUSBPS_TYPE_DEVICE_DESC:
		case XUSBPS_TYPE_DEVICE_QUALIFIER:
			ReplyLen = (int)XUsbPs_Ch9SetupDevDescReply(Reply, XUSBPS_REQ_REPLY_LEN);
			if (ReplyLen == 0) {
				Error = 1;
				break;
			}
			if (((SetupData->wValue >> 8) & 0xFF) == XUSBPS_TYPE_DEVICE_QUALIFIER) {
				Reply[0] = 10;
				Reply[1] = 0x06;
				Reply[2] = 0x00;
				Reply[3] = 0x02;
				Reply[4] = 0xFF;
				Reply[5] = 0x00;
				Reply[6] = 0x00;
				Reply[7] = 0x40;
				Reply[8] = 0x01;
				Reply[9] = 0x00;
				ReplyLen = 10;
			}
			if (ReplyLen > SetupData->wLength) {
				ReplyLen = SetupData->wLength;
			}
			(void)XUsbPs_EpBufferSend(InstancePtr, 0, Reply, ReplyLen);
			break;

		case XUSBPS_TYPE_CONFIG_DESC:
			ReplyLen = (int)XUsbPs_Ch9SetupCfgDescReply(Reply, XUSBPS_REQ_REPLY_LEN);
			if (ReplyLen == 0) {
				Error = 1;
				break;
			}
			if (ReplyLen > SetupData->wLength) {
				ReplyLen = SetupData->wLength;
			}
			(void)XUsbPs_EpBufferSend(InstancePtr, 0, Reply, ReplyLen);
			break;

		case XUSBPS_TYPE_STRING_DESC:
			if ((SetupData->wValue & 0xFF) == USB_WCID_STRING_INDEX) {
				ReplyLen = sizeof(kMsOsStringDescriptor);
				if (ReplyLen > SetupData->wLength) {
					ReplyLen = SetupData->wLength;
				}
				(void)XUsbPs_EpBufferSend(InstancePtr, 0, (u8 *)kMsOsStringDescriptor, ReplyLen);
			} else {
				ReplyLen = (int)XUsbPs_Ch9SetupStrDescReply(Reply, XUSBPS_REQ_REPLY_LEN, (u8)(SetupData->wValue & 0xFF));
				if (ReplyLen == 0) {
					Error = 1;
					break;
				}
				if (ReplyLen > SetupData->wLength) {
					ReplyLen = SetupData->wLength;
				}
				(void)XUsbPs_EpBufferSend(InstancePtr, 0, Reply, ReplyLen);
			}
			break;

		default:
			Error = 1;
			break;
		}
		break;

	case XUSBPS_REQ_SET_CONFIGURATION:
		if (((SetupData->wValue & 0xFF) != 0) && ((SetupData->wValue & 0xFF) != 1)) {
			Error = 1;
			break;
		}
		UsbLocalPtr->CurrentConfig = (u8)(SetupData->wValue & 0xFF);
		XUsbPs_SetConfiguration(InstancePtr, UsbLocalPtr->CurrentConfig);
		XUsbPs_SetConfigurationApp(InstancePtr, SetupData);
		(void)XUsbPs_EpBufferSend(InstancePtr, 0, NULL, 0);
		break;

	case XUSBPS_REQ_GET_CONFIGURATION:
		(void)XUsbPs_EpBufferSend(InstancePtr, 0, &UsbLocalPtr->CurrentConfig, 1);
		break;

	case XUSBPS_REQ_CLEAR_FEATURE:
		if ((SetupData->bmRequestType & XUSBPS_STATUS_MASK) == XUSBPS_STATUS_ENDPOINT &&
			SetupData->wValue == XUSBPS_ENDPOINT_HALT) {
			int EpNum = SetupData->wIndex;
			if (EpNum & 0x80) {
				XUsbPs_ClrBits(InstancePtr, XUSBPS_EPCRn_OFFSET(EpNum & 0xF), XUSBPS_EPCR_TXS_MASK);
			} else {
				XUsbPs_ClrBits(InstancePtr, XUSBPS_EPCRn_OFFSET(EpNum & 0xF), XUSBPS_EPCR_RXS_MASK);
			}
			(void)XUsbPs_EpBufferSend(InstancePtr, 0, NULL, 0);
		} else {
			Error = 1;
		}
		break;

	case XUSBPS_REQ_SET_FEATURE:
		if ((SetupData->bmRequestType & XUSBPS_STATUS_MASK) == XUSBPS_STATUS_ENDPOINT &&
			SetupData->wValue == XUSBPS_ENDPOINT_HALT) {
			int EpNum = SetupData->wIndex;
			if (EpNum & 0x80) {
				XUsbPs_SetBits(InstancePtr, XUSBPS_EPCRn_OFFSET(EpNum & 0xF), XUSBPS_EPCR_TXS_MASK);
			} else {
				XUsbPs_SetBits(InstancePtr, XUSBPS_EPCRn_OFFSET(EpNum & 0xF), XUSBPS_EPCR_RXS_MASK);
			}
			(void)XUsbPs_EpBufferSend(InstancePtr, 0, NULL, 0);
		} else if ((SetupData->bmRequestType & XUSBPS_STATUS_MASK) == XUSBPS_STATUS_DEVICE &&
				   SetupData->wValue == XUSBPS_TEST_MODE) {
			(void)XUsbPs_EpBufferSend(InstancePtr, 0, NULL, 0);
		} else {
			Error = 1;
		}
		break;

	case XUSBPS_REQ_SET_INTERFACE:
		XUsbPs_SetInterfaceHandler(InstancePtr, SetupData);
		(void)XUsbPs_EpBufferSend(InstancePtr, 0, NULL, 0);
		break;

	default:
		Error = 1;
		break;
	}

	if (Error) {
		XUsbPs_EpStall(InstancePtr, 0, XUSBPS_EP_DIRECTION_IN | XUSBPS_EP_DIRECTION_OUT);
	}
}

static int XUsbPs_HandleVendorReq(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData)
{
	u32 reply_len;

	if ((SetupData->bRequest == USB_WCID_VENDOR_CODE) &&
		(SetupData->wIndex == USB_WCID_COMPAT_ID_INDEX) &&
		((SetupData->bmRequestType & 0x80U) != 0U)) {
		reply_len = sizeof(kMsCompatIdDescriptor);
		if (reply_len > SetupData->wLength) {
			reply_len = SetupData->wLength;
		}
		return XUsbPs_EpBufferSend(InstancePtr, 0, (u8 *)kMsCompatIdDescriptor, reply_len);
	}

	XUsbPs_EpStall(InstancePtr, 0, XUSBPS_EP_DIRECTION_IN | XUSBPS_EP_DIRECTION_OUT);
	return XST_FAILURE;
}

int usb_ch9_is_configured(void)
{
	return g_configured;
}

void usb_ch9_reset_configured(void)
{
	g_configured = 0;
	usb_ch9_flush_configured();
}

void XUsbPs_SetConfigurationApp(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData)
{
	(void)InstancePtr;
	(void)SetupData;
}

void XUsbPs_SetInterfaceHandler(XUsbPs *InstancePtr, XUsbPs_SetupData *SetupData)
{
	(void)InstancePtr;
	(void)SetupData;
}

void XUsbPs_SetConfiguration(XUsbPs *InstancePtr, int ConfigIdx)
{
	if (InstancePtr == NULL) {
		return;
	}

	if (ConfigIdx != 1) {
		g_configured = 0;
		usb_ch9_flush_configured();
		return;
	}

	XUsbPs_EpEnable(InstancePtr, 1, XUSBPS_EP_DIRECTION_OUT);
	XUsbPs_EpEnable(InstancePtr, 1, XUSBPS_EP_DIRECTION_IN);
	XUsbPs_SetBits(InstancePtr, XUSBPS_EPCR1_OFFSET,
		XUSBPS_EPCR_TXT_BULK_MASK |
		XUSBPS_EPCR_RXT_BULK_MASK |
		XUSBPS_EPCR_TXR_MASK |
		XUSBPS_EPCR_RXR_MASK);
	XUsbPs_EpPrime(InstancePtr, 1, XUSBPS_EP_DIRECTION_OUT);
	g_configured = 1;
	usb_ch9_flush_configured();
}
