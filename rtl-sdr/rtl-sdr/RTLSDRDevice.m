//
//  rtl_sdr.m
//  rtl-sdr
//
//  Created by William Dillon on 6/7/12.
//  Copyright (c) 2012. All rights reserved. Licensed under the GPL v.2
//

#import "RTLSDRDevice.h"
#import "RTLSDRTuner.h"

#import <mach/mach_time.h>

#import "radioProbes.h"

#define err_get_system(err) (((err)>>26)&0x3f)
#define err_get_sub(err) (((err)>>14)&0xfff)
#define err_get_code(err) ((err)&0x3fff)

//#define DEBUG_USB

// OSMOCOM RTL-SDR DERIVED CODE
#define DEFAULT_BUF_NUMBER	32
#define DEFAULT_BUF_LENGTH	(16 * 32 * 512)

#define DEF_RTL_XTAL_FREQ	28800000
#define MIN_RTL_XTAL_FREQ	(DEF_RTL_XTAL_FREQ - 1000)
#define MAX_RTL_XTAL_FREQ	(DEF_RTL_XTAL_FREQ + 1000)

#define MAX_SAMP_RATE		3200000

//#define CTRL_IN	(LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_ENDPOINT_IN)
//#define CTRL_OUT	(LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_ENDPOINT_OUT)
#define CTRL_TIMEOUT	1000
#define BULK_TIMEOUT	0

/* two raised to the power of n */
#define TWO_POW(n)		((double)(1ULL<<(n)))

typedef struct rtlsdr_dongle {
	uint16_t vid;
	uint16_t pid;
	const char *name;
} rtlsdr_dongle_t;

/*
 * Please add your device here and send a patch to osmocom-sdr@lists.osmocom.org
 */
static rtlsdr_dongle_t known_devices[] = {
	{ 0x0bda, 0x2832, "Generic RTL2832U (e.g. hama nano)" },
	{ 0x0bda, 0x2838, "ezcap USB 2.0 DVB-T/DAB/FM dongle" },
	{ 0x0ccd, 0x00a9, "Terratec Cinergy T Stick Black (rev 1)" },
	{ 0x0ccd, 0x00b3, "Terratec NOXON DAB/DAB+ USB dongle (rev 1)" },
	{ 0x0ccd, 0x00b4, "Terratec NOXON DAB/DAB+ USB dongle (rev 1)" },
	{ 0x0ccd, 0x00b7, "Terratec NOXON DAB/DAB+ USB dongle (rev 1)" },
	{ 0x0ccd, 0x00c6, "Terratec NOXON DAB/DAB+ USB dongle (rev 1)" },
	{ 0x0ccd, 0x00d3, "Terratec Cinergy T Stick RC (Rev.3)" },
	{ 0x0ccd, 0x00d7, "Terratec T Stick PLUS" },
	{ 0x0ccd, 0x00e0, "Terratec NOXON DAB/DAB+ USB dongle (rev 2)" },
	{ 0x185b, 0x0620, "Compro Videomate U620F"},
	{ 0x185b, 0x0650, "Compro Videomate U650F"},
	{ 0x185b, 0x0680, "Compro Videomate U680F"},
	{ 0x1f4d, 0xa803, "Sweex DVB-T USB" },
	{ 0x1f4d, 0xb803, "GTek T803" },
	{ 0x1f4d, 0xc803, "Lifeview LV5TDeluxe" },
	{ 0x1f4d, 0xd286, "MyGica TD312" },
	{ 0x1f4d, 0xd803, "PROlectrix DV107669" },
	{ 0x1b80, 0xd398, "Zaapa ZT-MINDVBZP" },
	{ 0x1b80, 0xd3a4, "Twintech UT-40" },
	{ 0x1d19, 0x1101, "Dexatek DK DVB-T Dongle (Logilink VG0002A)" },
	{ 0x1d19, 0x1102, "Dexatek DK DVB-T Dongle (MSI DigiVox mini II V3.0)" },
	{ 0x1d19, 0x1103, "Dexatek Technology Ltd. DK 5217 DVB-T Dongle" },
	{ 0x0458, 0x707f, "Genius TVGo DVB-T03 USB dongle (Ver. B)" },
	{ 0x1b80, 0xd393, "GIGABYTE GT-U7300" },
	{ 0x1b80, 0xd394, "DIKOM USB-DVBT HD" },
	{ 0x1b80, 0xd395, "Peak 102569AGPK" },
	{ 0x1b80, 0xd39d, "SVEON STV20 DVB-T USB & FM" },
};

enum usb_reg {
	USB_SYSCTL		= 0x2000,
	USB_CTRL		= 0x2010,
	USB_STAT		= 0x2014,
	USB_EPA_CFG		= 0x2144,
	USB_EPA_CTL		= 0x2148,
	USB_EPA_MAXPKT		= 0x2158,
	USB_EPA_MAXPKT_2	= 0x215a,
	USB_EPA_FIFO_CFG	= 0x2160,
};

enum sys_reg {
	DEMOD_CTL		= 0x3000,
	GPO			= 0x3001,
	GPI			= 0x3002,
	GPOE			= 0x3003,
	GPD			= 0x3004,
	SYSINTE			= 0x3005,
	SYSINTS			= 0x3006,
	GP_CFG0			= 0x3007,
	GP_CFG1			= 0x3008,
	SYSINTE_1		= 0x3009,
	SYSINTS_1		= 0x300a,
	DEMOD_CTL_1		= 0x300b,
	IR_SUSPEND		= 0x300c,
};

enum blocks {
	DEMODB			= 0,
	USBB			= 1,
	SYSB			= 2,
	TUNB			= 3,
	ROMB			= 4,
	IRB			= 5,
	IICB			= 6,
};

// END OSMOCOM CODE

static NSArray *deviceList;
static dispatch_once_t onceToken;

//NSString *stringFromUSBError(int errorValue)
//{
//    switch (errorValue) {
//        case LIBUSB_ERROR_TIMEOUT:
//            return @"Timeout";
//        case LIBUSB_ERROR_PIPE:
//            return @"Control request not supported";
//        case LIBUSB_ERROR_NO_DEVICE:
//            return @"Device disconnected";
//        default:
//            return @"Unknown error";
//    }
//}

@implementation RTLSDRDevice

@synthesize tuner;

#pragma mark -
#pragma mark Device searching and enumeration

+(const char *)findKnownDeviceVendorID:(uint16_t)vid
                              DeviceID:(uint16_t)did
{
    unsigned int i;
    int nDevices = sizeof(known_devices)/sizeof(rtlsdr_dongle_t);

    for (i = 0; i < nDevices; i++ ) {
        if (known_devices[i].vid == vid &&
            known_devices[i].pid == did) {
            return known_devices[i].name;
        }
    }
    
    return nil;
}

+(NSInteger)deviceCount
{
    return [[RTLSDRDevice deviceList] count];    
}

+(NSArray *)deviceList
{
    // Enumerate devices once at the start, after just return the array.
    dispatch_once(&onceToken, ^{
        kern_return_t kretval;
        NSMutableArray *tempDeviceList = [[NSMutableArray alloc] init];

        // Create matching dictionaries for all USB devices
        CFMutableDictionaryRef usbMatchingDictionary = nil;
        io_iterator_t iterator;
        usbMatchingDictionary = IOServiceMatching(kIOUSBDeviceClassName);
        kretval = IOServiceGetMatchingServices(kIOMasterPortDefault, 
                                               usbMatchingDictionary, 
                                               &iterator);
        
        if (kretval != kIOReturnSuccess) {
            NSLog(@"Error getting deviceList!");
        }
        
        // Scan through the USB Devices looking for those that match
        // our known devices.  The deviceList contains dictionaries of
        // NSString names and locationIDs.  The locationID is used to
        // find the device again when the user opens it.
        io_service_t usbDevice;
        while ((usbDevice = IOIteratorNext(iterator))) {
            // Now, we need to get the product and vendor IDs of this device.
            // In order to do this, we need to create an IOUSBDeviceInterface for our device.
            // This will create the necessary connections between our
            // userland application and the kernel object for the USB Device.
            SInt32				score;
            IOCFPlugInInterface	**plugInInterface = NULL;        
            kretval = IOCreatePlugInInterfaceForService(usbDevice,
                                                        kIOUSBDeviceUserClientTypeID,
                                                        kIOCFPlugInInterfaceID,
                                                        &plugInInterface, &score);
            
            if ((kIOReturnSuccess != kretval) || !plugInInterface) {
                fprintf(stderr, "IOCreatePlugInInterfaceForService returned 0x%08x.\n", kretval);
                continue;
            }
            
            // Use the plugin interface to retrieve the device interface.
            IOUSBDeviceInterface **deviceInterface;
            HRESULT 			 res;
            res = (*plugInInterface)->QueryInterface(plugInInterface,
                                                     CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                                     (LPVOID*) &deviceInterface);
            if (res != kIOReturnSuccess) {
                NSLog(@"Unable to query interface.");
                continue;
            }

            // Now done with the plugin interface.
            (*plugInInterface)->Release(plugInInterface);
            
            // Now that we have the IOUSBDeviceInterface,
            // we can call the routines in IOUSBLib.h.
            // In this case, fetch the product and vendor IDs.
            // The locationID uniquely identifies the device
            // and will remain the same, even across reboots,
            // so long as the bus topology doesn't change.
            
            UInt32 idLocation;
            UInt16 idProduct, idVendor;
            kretval = (*deviceInterface)->GetLocationID(deviceInterface, &idLocation);
            if (kretval != kIOReturnSuccess) {
                NSLog(@"Error getting locationID.");
                continue;
            }

            kretval = (*deviceInterface)->GetDeviceProduct(deviceInterface, &idProduct);
            if (kretval != kIOReturnSuccess) {
                NSLog(@"Error getting device product.");
                continue;
            }

            kretval = (*deviceInterface)->GetDeviceVendor(deviceInterface, &idVendor);
            if (kretval != kIOReturnSuccess) {
                NSLog(@"Error getting device vendor.");
                continue;
            }

            // Search through the known devices array, looking for matches
            NSString *deviceNameString = nil;
            const char *name = [self findKnownDeviceVendorID:idVendor
                                                    DeviceID:idProduct];
            if (name) {
                NSNumber *locationIDNumber;
                deviceNameString = [NSString stringWithCString:name
                                                      encoding:NSUTF8StringEncoding];
                locationIDNumber = [NSNumber numberWithInteger:idLocation];
                NSDictionary *deviceDict = [NSDictionary dictionaryWithObjectsAndKeys:
                                            deviceNameString, @"deviceName",
                                            locationIDNumber, @"deviceLocation", nil];
                [tempDeviceList addObject:deviceDict];
            }
            
#ifdef DEBUG_USB
            else {
                NSLog(@"ignoring USB Device \"%@\" PID: 0x%04x VID: 0x%04x",
                      deviceNameString, idProduct, idVendor);
            }
#endif            
            // Done with this USB device; release the reference added by IOIteratorNext
            kretval = IOObjectRelease(usbDevice);
            if (kretval != kIOReturnSuccess) {
                NSLog(@"Error releasing object.");
                continue;
            }
        }
        
//        CFRelease(&iterator);
        
        deviceList = tempDeviceList;
    });
    
    return deviceList;
    
}


#pragma mark -
#pragma mark Register read/write methods
- (uint16_t)readAddress:(uint16_t)addr
              fromBlock:(uint8_t)block
                 length:(uint8_t)bytes
{
    // OSMOCOM RTL-SDR DERIVED CODE
	unsigned char data[2] = {0,0};
	uint16_t index = (block << 8);

//	r = libusb_control_transfer(devh, CTRL_IN, 0, addr, index, data, bytes, CTRL_TIMEOUT);
    // END OSMOCOM CODE

    IOUSBDevRequest     request;
    request.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice);
    request.bRequest = 0;
    request.wValue = addr;
    request.wIndex = index;
    request.wLength = bytes;
    request.pData = data;
    
    kern_return_t kretval = (*dev)->DeviceRequest(dev, &request);

#ifdef DEBUG_USB
    NSLog(@"register read address 0x%x block %d data 0x%x length %d\n", addr, block, *(uint16_t *)data, bytes);
#endif
    
    if (kretval != KERN_SUCCESS) {
		NSLog(@"%s failed: %d", __FUNCTION__, kretval);
    }
    
	return (data[1] << 8) | data[0];
}

- (void)writeValue:(uint16_t)value
         AtAddress:(uint16_t)addr
           InBlock:(uint8_t)block
            Length:(uint8_t)bytes;
{
    // OSMOCOM RTL-SDR DERIVED CODE
	unsigned char data[2] = {0,0};
    
	uint16_t index = (block << 8) | 0x10;
    
	if (bytes == 1)
		data[0] = value & 0xff;
	else
		data[0] = value >> 8;
    
	data[1] = value & 0xff;
//	r = libusb_control_transfer(devh, CTRL_OUT, 0, addr, index, data, bytes, CTRL_TIMEOUT);
    // END OSMOCOM CODE
    
    IOUSBDevRequest     request;
    request.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice);
    request.bRequest = 0;
    request.wValue = addr;
    request.wIndex = index;
    request.wLength = bytes;
    request.pData = data;
    
#ifdef DEBUG_USB
    NSLog(@"register write address 0x%x block %d data 0x%x length %d\n", addr, block, *(uint16_t *)data, bytes);
#endif
    
    kern_return_t kretval = (*dev)->DeviceRequest(dev, &request);
    
    if (kretval != KERN_SUCCESS) {
		NSLog(@"%s failed: %d", __FUNCTION__, kretval);
    }
}

- (uint16_t)demodReadAddress:(uint16_t)addr
                   fromBlock:(uint8_t)block
                      length:(uint8_t)bytes
{
    // OSMOCOM RTL-SDR DERIVED CODE
	unsigned char data[2] = {0,0};
    
	uint16_t index = block;
	addr = (addr << 8) | 0x20;
    
//	r = libusb_control_transfer(dev->devh, CTRL_IN, 0, addr, index, data, len, CTRL_TIMEOUT);
    // END OSMOCOM CODE
    
    IOUSBDevRequest     request;
    request.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice);
    request.bRequest = 0;
    request.wValue = addr;
    request.wIndex = index;
    request.wLength = bytes;
    request.pData = data;
    kern_return_t kretval = (*dev)->DeviceRequest(dev, &request);

    if (kretval != KERN_SUCCESS) {
		NSLog(@"%s failed: %d", __FUNCTION__, kretval);
    }
    
#ifdef DEBUG_USB
    NSLog(@"demod read address 0x%x block %d data 0x%x length %d\n", addr, block, *(uint16_t *)data, bytes);
#endif
    
	return (data[1] << 8) | data[0];
}

- (void)demodWriteValue:(uint16_t)value AtAddress:(uint16_t)addr InBlock:(uint8_t)block Length:(uint8_t)bytes;
{
    // OSMOCOM RTL-SDR DERIVED CODE
	unsigned char data[2] = {0,0};
	uint16_t index = 0x10 | block;
	addr = (addr << 8) | 0x20;
    
	if (bytes == 1)
		data[0] = value & 0xff;
	else
		data[0] = value >> 8;
    
	data[1] = value & 0xff;

//	r = libusb_control_transfer(dev->devh, CTRL_OUT, 0, addr, index, data, len, CTRL_TIMEOUT);
    // END OSMOCOM CODE
    
#ifdef DEBUG_USB
    NSLog(@"demod write address 0x%x block %d data 0x%x length %d\n", addr, block, *(uint16_t *)data, bytes);
#endif
    
    IOUSBDevRequest     request;
    request.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice);
    request.bRequest = 0;
    request.wValue = addr;
    request.wIndex = index;
    request.wLength = bytes;
    request.pData = data;
    
    kern_return_t kretval = (*dev)->DeviceRequest(dev, &request);
    
    if (kretval != KERN_SUCCESS) {
		NSLog(@"%s failed: %d", __FUNCTION__, kretval);
    }
    
    [self demodReadAddress:0x01 fromBlock:0x0a length:1];
}

- (void)setI2cRepeater:(bool)enabled
{
    if (enabled) {
        [self demodWriteValue:0x18 AtAddress:0x01 InBlock:1 Length:1];
//        rtlsdr_demod_write_reg(dev, 1, 0x01, on ? 0x18 : 0x10, 1);
    } else {
        [self demodWriteValue:0x10 AtAddress:0x01 InBlock:1 Length:1];
//        rtlsdr_demod_write_reg(dev, 1, 0x01, on ? 0x18 : 0x10, 1);
    }
}

- (int)readArray:(uint8_t*)array fromAddress:(uint16_t)addr inBlock:(uint8_t)block length:(uint8_t)bytes
{
	uint16_t index = (block << 8);
    
    IOUSBDevRequest     request;
    request.bmRequestType = USBmakebmRequestType(kUSBIn, kUSBVendor, kUSBDevice);
    request.bRequest = 0;
    request.wValue = addr;
    request.wIndex = index;
    request.wLength = bytes;
    request.pData = array;
    
#ifdef DEBUG_USB
    NSLog(@"array read address 0x%x block %d length %d\n", addr, block, bytes);
#endif
    
    kern_return_t kretval = (*dev)->DeviceRequest(dev, &request);

	return kretval;
}

- (int)writeArray:(uint8_t *)array toAddress:(uint16_t)addr inBlock:(uint8_t)block length:(uint8_t)bytes
{
	uint16_t index = (block << 8) | 0x10;

    IOUSBDevRequest     request;
    request.bmRequestType = USBmakebmRequestType(kUSBOut, kUSBVendor, kUSBDevice);
    request.bRequest = 0;
    request.wValue = addr;
    request.wIndex = index;
    request.wLength = bytes;
    request.pData = array;
    
#ifdef DEBUG_USB
    NSLog(@"array write address 0x%x block %d length %d", addr, block, bytes);
#endif
    
    kern_return_t kretval = (*dev)->DeviceRequest(dev, &request);
    
    if (kretval != kIOReturnSuccess) {
        int system = err_get_system(kretval);
        int subsys = err_get_sub(kretval);
        int code   = err_get_code(kretval);
        
        printf("Device array write to address 0x%x failed (%d): system 0x%x, subsystem %d, code 0x%x\n",
               addr, kretval, system, subsys, code);
        return kretval;
    }

	return kretval;

}

- (int)writeI2cRegister:(uint8_t)reg atAddress:(uint8_t)i2c_addr withValue:(uint8_t)val
{
	uint16_t addr = i2c_addr;
	uint8_t data[2];
    
	data[0] = reg;
	data[1] = val;

#ifdef DEBUG_USB
    NSLog(@"I2C write register 0x%x address 0x%x data 0x%x", reg, i2c_addr, val);
#endif

    return [self writeArray:(uint8_t *)&data toAddress:addr inBlock:IICB length:2];
}

- (uint8_t)readI2cRegister:(uint8_t)reg fromAddress:(uint8_t)i2c_addr
{
	uint16_t addr = i2c_addr;
	uint8_t data = 0;
    
    [self writeArray:&reg toAddress:addr   inBlock:IICB length:1];
    [self readArray:&data fromAddress:addr inBlock:IICB length:1];
    
#ifdef DEBUG_USB
    NSLog(@"I2C read register 0x%x address 0x%x data 0x%x", reg, i2c_addr, data);
#endif

	return data;
}

- (int)writeI2cAtAddress:(uint8_t)i2c_addr withBuffer:(uint8_t *)buffer length:(int)len
{
	uint16_t addr = i2c_addr;

#ifdef DEBUG_USB
    NSLog(@"i2c write address 0x%x data 0x%x length %d", i2c_addr, *(uint16_t *)buffer, len);
#endif
    
    return [self writeArray:buffer toAddress:addr inBlock:IICB length:len];
}

- (int)readI2cAtAddress:(uint8_t)i2c_addr withBuffer:(uint8_t *)buffer length:(int)len
{
	uint16_t addr = i2c_addr;

    int retval = [self readArray:buffer fromAddress:addr inBlock:IICB length:len];
    
#ifdef DEBUG_USB
    NSLog(@"i2c read address 0x%x data 0x%x length %d", i2c_addr, *buffer, len);
#endif

    return retval;
}

- (void)setGpioBit:(uint8_t)gpio value:(int)value
{
	uint8_t r;
    
	gpio = 1 << gpio;

//	r = rtlsdr_read_reg(dev, SYSB, GPO, 1);
    r = [self readAddress:GPO fromBlock:SYSB length:1];
	r = value ? (r | gpio) : (r & ~gpio);
//	rtlsdr_write_reg(dev, SYSB, GPO, r, 1);
    [self writeValue:r AtAddress:GPO InBlock:SYSB Length:1];
}

- (void)setGpioOutput:(uint8_t)gpio
{
	int r;
	gpio = 1 << gpio;
    
//	r = rtlsdr_read_reg(dev, SYSB, GPD, 1);
    r = [self readAddress:GPD fromBlock:SYSB length:1];

//	rtlsdr_write_reg(dev, SYSB, GPO, r & ~gpio, 1);
    [self writeValue:r & ~gpio AtAddress:GPO InBlock:SYSB Length:1];

//	r = rtlsdr_read_reg(dev, SYSB, GPOE, 1);
    r = [self readAddress:GPOE fromBlock:SYSB length:1];

//	rtlsdr_write_reg(dev, SYSB, GPOE, r | gpio, 1);
    [self writeValue:r | gpio AtAddress:GPOE InBlock:SYSB Length:1];
}

#pragma mark -
#pragma mark Class initialization/deallocation
- (void)initBaseband
{
    // OSMOCOM RTL-SDR DERIVED CODE
    unsigned int i;
    
	/* default FIR coefficients used for DAB/FM by the Windows driver,
	 * the DVB driver uses different ones */
	uint8_t fir_coeff[] = {
		0xca, 0xdc, 0xd7, 0xd8, 0xe0, 0xf2, 0x0e, 0x35, 0x06, 0x50,
		0x9c, 0x0d, 0x71, 0x11, 0x14, 0x71, 0x74, 0x19, 0x41, 0xa5,
	};
    
	/* initialize USB */
//  rtlsdr_write_reg(dev, block,  addr,     val, len);
//	rtlsdr_write_reg(dev, USBB, USB_SYSCTL, 0x09, 1);
    [self writeValue:0x09 AtAddress:USB_SYSCTL InBlock:USBB Length:1];
    
//	rtlsdr_write_reg(dev, USBB, USB_EPA_MAXPKT, 0x0002, 2);
    [self writeValue:0x0002 AtAddress:USB_EPA_MAXPKT InBlock:USBB Length:2];
//	rtlsdr_write_reg(dev, USBB, USB_EPA_CTL, 0x1002, 2);
    [self writeValue:0x1002 AtAddress:USB_EPA_CTL InBlock:USBB Length:2];
    
	/* poweron demod */
//	rtlsdr_write_reg(dev, SYSB, DEMOD_CTL_1, 0x22, 1);
    [self writeValue:0x22 AtAddress:DEMOD_CTL_1 InBlock:SYSB Length:1];
//	rtlsdr_write_reg(dev, SYSB, DEMOD_CTL, 0xe8, 1);
    [self writeValue:0xe8 AtAddress:DEMOD_CTL InBlock:SYSB Length:1];
    
	/* reset demod (bit 3, soft_rst) */
//	rtlsdr_demod_write_reg(dev, 1, 0x01, 0x14, 1);
    [self demodWriteValue:0x14 AtAddress:0x01 InBlock:1 Length:1];
//	rtlsdr_demod_write_reg(dev, 1, 0x01, 0x10, 1);
    [self demodWriteValue:0x10 AtAddress:0x01 InBlock:1 Length:1];
    
	/* disable spectrum inversion and adjacent channel rejection */
//	rtlsdr_demod_write_reg(dev, 1, 0x15, 0x00, 1);
    [self demodWriteValue:0x00   AtAddress:0x15 InBlock:1 Length:1];
//	rtlsdr_demod_write_reg(dev, 1, 0x16, 0x0000, 2);
    [self demodWriteValue:0x0000 AtAddress:0x16 InBlock:1 Length:2];
    
	/* clear both DDC shift and IF frequency registers  */
	for (i = 0; i < 6; i++) {
//		rtlsdr_demod_write_reg(dev, 1, 0x16 + i, 0x00, 1);
        [self demodWriteValue:0x00 AtAddress:(0x16 + i) InBlock:1 Length:1];
    }
    
	/* set FIR coefficients */
	for (i = 0; i < sizeof (fir_coeff); i++) {
//		rtlsdr_demod_write_reg(dev, 1, 0x1c + i, fir_coeff[i], 1);
        [self demodWriteValue:fir_coeff[i] AtAddress:(0x1c + i) InBlock:1 Length:1];
    }
    
	/* enable SDR mode, disable DAGC (bit 5) */
//	rtlsdr_demod_write_reg(dev, 0, 0x19, 0x05, 1);
    [self demodWriteValue:0x05 AtAddress:0x19 InBlock:0 Length:1];

	/* init FSM state-holding register */
//	rtlsdr_demod_write_reg(dev, 1, 0x93, 0xf0, 1);
    [self demodWriteValue:0xf0 AtAddress:0x93 InBlock:1 Length:1];
//  rtlsdr_demod_write_reg(dev, 1, 0x94, 0x0f, 1);
    [self demodWriteValue:0x0f AtAddress:0x94 InBlock:1 Length:1];

	/* disable AGC (en_dagc, bit 0) (this seems to have no effect) */
//	rtlsdr_demod_write_reg(dev, 1, 0x11, 0x00, 1);
    [self demodWriteValue:0x00 AtAddress:0x11 InBlock:1 Length:1];
    
    /* disable RF and IF AGC loop */
//	rtlsdr_demod_write_reg(dev, 1, 0x04, 0x00, 1);
    [self demodWriteValue:0x00 AtAddress:0x04 InBlock:1 Length:1];

	/* disable PID filter (enable_PID = 0) */
//	rtlsdr_demod_write_reg(dev, 0, 0x61, 0x60, 1);
    [self demodWriteValue:0x60 AtAddress:0x61 InBlock:0 Length:1];
    
	/* opt_adc_iq = 0, default ADC_I/ADC_Q datapath */
//	rtlsdr_demod_write_reg(dev, 0, 0x06, 0x80, 1);
    [self demodWriteValue:0x80 AtAddress:0x06 InBlock:0 Length:1];
    
	/* Enable Zero-IF mode (en_bbin bit), DC cancellation (en_dc_est),
	 * IQ estimation/compensation (en_iq_comp, en_iq_est) */
//	rtlsdr_demod_write_reg(dev, 1, 0xb1, 0x1b, 1);
    [self demodWriteValue:0x1b AtAddress:0xb1 InBlock:1 Length:1];
    
    /* disable 4.096 MHz clock output on pin TP_CK0 */
//	rtlsdr_demod_write_reg(dev, 0, 0x0d, 0x83, 1);
    [self demodWriteValue:0x83 AtAddress:0x0d InBlock:0 Length:1];
}

- (id)init
{
    self = [super init];
    if (self) {
        tunerClock = 28800000;
    }
    
    return self;
}

- (bool)configureDevice
{
    UInt8                           numConfig;
    IOReturn                        kretval;
    IOUSBConfigurationDescriptorPtr configDesc;
    
    //Get the number of configurations. The sample code always chooses
    //the first configuration (at index 0) but your code may need a
    //different one
    kretval = (*dev)->GetNumberOfConfigurations(dev, &numConfig);
    if (kretval != kIOReturnSuccess) {
        return NO;
    }
    
    //Get the configuration descriptor for index 0
    kretval = (*dev)->GetConfigurationDescriptorPtr(dev, 0, &configDesc);
    if (kretval != kIOReturnSuccess) {
        printf("Couldn’t get configuration descriptor for index %d (err = %08x)\n", 0, kretval);
        return NO;
    }
    
    //Set the device’s configuration. The configuration value is found in
    //the bConfigurationValue field of the configuration descriptor
    kretval = (*dev)->SetConfiguration(dev, configDesc->bConfigurationValue);
    if (kretval != kIOReturnSuccess) {
        printf("Couldn’t set configuration to value %d (err = %08x)\n", 0, kretval);
        return NO;
    }
    
    return YES;
}

// This entire function is copied almost wholesale from the Apple documentation
- (bool)findInterfaces
{
    IOReturn kretval;
    UInt8    interfaceClass;
    UInt8    interfaceSubClass;
    IOUSBFindInterfaceRequest  request;
    request.bInterfaceClass    = kIOUSBFindInterfaceDontCare;
    request.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    request.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    request.bAlternateSetting  = kIOUSBFindInterfaceDontCare;
    
    //Get an iterator for the interfaces on the device
    io_iterator_t               iterator;
    kretval = (*dev)->CreateInterfaceIterator(dev, &request, &iterator);
    if (kretval != kIOReturnSuccess) {
        NSLog(@"Unable to create interface iterator.");
        return NO;
    }
    
    io_service_t usbInterface;
    while ((usbInterface = IOIteratorNext(iterator)) != 0)
    {
        //Create an intermediate plug-in
        SInt32                      score;
        IOCFPlugInInterface         **plugInInterface = NULL;
        kretval = IOCreatePlugInInterfaceForService(usbInterface,
                                               kIOUSBInterfaceUserClientTypeID,
                                               kIOCFPlugInInterfaceID,
                                               &plugInInterface, &score);
        if (kretval != kIOReturnSuccess) {
            NSLog(@"Unable to create plugin interface for service.");
            continue;
        }

        //Release the usbInterface object after getting the plug-in
        kretval = IOObjectRelease(usbInterface);
        if ((kretval != kIOReturnSuccess) || !plugInInterface)
        {
            printf("Unable to create a plug-in (%08x)\n", kretval);
            break;
        }
        
        //Now create the device interface for the interface
        IOUSBInterfaceInterface     **interface = NULL;
        HRESULT                     result;
        result = (*plugInInterface)->QueryInterface(plugInInterface,
                                                    CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID),
                                                    (LPVOID *) &interface);
        //No longer need the intermediate plug-in
        (*plugInInterface)->Release(plugInInterface);
        
        if (result || !interface)
        {
            printf("Couldn’t create a device interface for the interface (%08x)\n", (int) result);
            break;
        }

        kretval = (*interface)->GetInterfaceClass(interface,    &interfaceClass);
        if (kretval != kIOReturnSuccess) {
            NSLog(@"Unable to get interface class.");
            continue;
        }

        kretval = (*interface)->GetInterfaceSubClass(interface, &interfaceSubClass);
        if (kretval != kIOReturnSuccess) {
            NSLog(@"Unable to get interface sub class.");
            continue;
        }

        //Now open the interface. This will cause the pipes associated with
        //the endpoints in the interface descriptor to be instantiated
        kretval = (*interface)->USBInterfaceOpen(interface);
        if (kretval != kIOReturnSuccess)
        {
            printf("Unable to open interface (%08x)\n", kretval);
            (void) (*interface)->Release(interface);
            break;
        }
        
        //Get the number of endpoints associated with this interface
        UInt8 interfaceNumEndpoints;
        kretval = (*interface)->GetNumEndpoints(interface,
                                           &interfaceNumEndpoints);
        if (kretval != kIOReturnSuccess)
        {
            printf("Unable to get number of endpoints (%08x)\n", kretval);
            (void) (*interface)->USBInterfaceClose(interface);
            (void) (*interface)->Release(interface);
            break;
        }
        
//        printf("Interface has %d endpoints\n", interfaceNumEndpoints);
        //Access each pipe in turn, starting with the pipe at index 1
        //The pipe at index 0 is the default control pipe and should be
        //accessed using (*usbDevice)->DeviceRequest() instead
        int pipeRef;
        for (pipeRef = 1; pipeRef <= interfaceNumEndpoints; pipeRef++)
        {
            IOReturn        kr2;
            UInt8           direction;
            UInt8           number;
            UInt8           transferType;
            UInt16          maxPacketSize;
            UInt8           interval;
            
            kr2 = (*interface)->GetPipeProperties(interface,
                                                  pipeRef, &direction,
                                                  &number, &transferType,
                                                  &maxPacketSize, &interval);
            if (kr2 != kIOReturnSuccess)
                printf("Unable to get properties of pipe %d (%08x)\n",
                       pipeRef, kr2);
            else
            {
                // Try to identify the correct interface robustly
                if (number == 1 && 
                    transferType == kUSBBulk &&
                    direction == kUSBIn) {
                    bulkInterface = (IOUSBInterfaceInterface220 **)interface;
                    bulkPacketSize = maxPacketSize;
                    bulkPipeRef = number;
//                    NSLog(@"Found bulk interface");
                    return YES;
                }

            }
        }
        
//Demonstrate asynchronous I/O
        kretval = (*interface)->CreateInterfaceAsyncEventSource(bulkInterface, &runLoopSource);
        if (kretval != kIOReturnSuccess)
        {
            printf("Unable to create asynchronous event source (%08x)\n", kretval);
            (void) (*bulkInterface)->USBInterfaceClose(bulkInterface);
            (void) (*bulkInterface)->Release(bulkInterface);
            break;
        }

        CFRunLoopRef cfRunLoop = [[NSRunLoop currentRunLoop] getCFRunLoop];
        CFRunLoopAddSource(cfRunLoop, runLoopSource, kCFRunLoopDefaultMode);
        printf("Asynchronous event source added to run loop\n");
    }
    
    return NO;
}

- (id)initWithDeviceIndex:(NSInteger)index
{
    self = [super init];
    if (self) {
        tunerClock = 28800000;
        
        asyncRunning = NO;
        asyncQueue = dispatch_queue_create("com.us.alternet.rtlsdr.async", DISPATCH_QUEUE_CONCURRENT);
        
        if (deviceList == nil) {
            [RTLSDRDevice deviceList];
        }
        
        if (index >= [deviceList count]) {
            NSLog(@"Attempting to access a device that doesn't exist.");
            self = nil;
            return nil;
        }
        
        NSNumber *idLocationNumber = [[deviceList objectAtIndex:index] objectForKey:@"deviceLocation"];
        UInt32 idLocation = (uint32_t)[idLocationNumber integerValue];
        
        // Get the deviceInterface from the location ID stored in the device List
        kern_return_t kretval;
        
        // Create matching dictionaries for all USB devices
        CFMutableDictionaryRef usbMatchingDictionary = nil;
        io_iterator_t iterator;
        usbMatchingDictionary = IOServiceMatching(kIOUSBDeviceClassName);

        // Filter out only the device with the correct location id
//        CFNumberRef locationID_CFNumber = CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &idLocation);
//        CFDictionarySetValue(usbMatchingDictionary, 
//                             CFSTR(kIOLocationMatchKey),
//                             locationID_CFNumber);
        

        kretval = IOServiceGetMatchingServices(kIOMasterPortDefault, 
                                               usbMatchingDictionary, 
                                               &iterator);
                
        if (kretval != kIOReturnSuccess || iterator == 0) {
            NSLog(@"Error getting deviceList!");
        }
        
        // Scan through the USB Devices looking for those that match
        // our known devices.  The deviceList contains dictionaries of
        // NSString names and locationIDs.  The locationID is used to
        // find the device again when the user opens it.
        io_service_t usbDevice;
        while ((usbDevice = IOIteratorNext(iterator))) {

            SInt32 score;
            IOCFPlugInInterface	**plugInInterface = NULL;        
            kretval = IOCreatePlugInInterfaceForService(usbDevice,
                                                        kIOUSBDeviceUserClientTypeID,
                                                        kIOCFPlugInInterfaceID,
                                                        &plugInInterface, &score);
            
            if ((kIOReturnSuccess != kretval) || !plugInInterface) {
                fprintf(stderr, "IOCreatePlugInInterfaceForService returned 0x%08x.\n", kretval);
                continue;
            }
            
            // Use the plugin interface to retrieve the device interface.
            HRESULT res;
            res = (*plugInInterface)->QueryInterface(plugInInterface,
                                                     CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                                                     (LPVOID*) &dev);
            if (IS_ERROR(res)) {
                NSLog(@"Error while querying USB interface.");
                continue;
            }
            
            // Now done with the plugin interface.
            (*plugInInterface)->Release(plugInInterface);
            
            UInt32 idLocationTest;
            kretval = (*dev)->GetLocationID(dev, &idLocationTest);
            if (kretval != kIOReturnSuccess) {
                NSLog(@"Error getting locationID.");
                continue;
            }

            // If the location ID matches the one stored in the dict, we've found the device
            if (idLocationTest == idLocation) {
                break;
            }
        }
        
        // Now the usbDevice is the one we want
        // and the deviceInterface is what we want
        //Open the device to change its state
        kretval = (*dev)->USBDeviceOpen(dev);
        if (kretval != kIOReturnSuccess)
        {
            printf("Unable to open device: %08x\n", kretval);
            (void) (*dev)->Release(dev);
            self = nil;
            return self;
        }

        //Configure device
        if (![self configureDevice])
        {
            printf("Unable to configure device: %08x\n", kretval);
            (void) (*dev)->USBDeviceClose(dev);
            (void) (*dev)->Release(dev);
            self = nil;
            return self;
        }
        
        rtlXtal = DEF_RTL_XTAL_FREQ;
        
        [self initBaseband];
        
        // Have the tuner class detect the type and create a class instance for itself.
        tuner = [RTLSDRTuner createTunerForDevice:self];
        
        if (tuner == nil) {
            self = nil;
            return self;
        } else {
        }
        
        [tuner setXtal:rtlXtal];
        
        [self findInterfaces];
    }
    
    return self;
}

#pragma mark -
#pragma mark Getters and Setters
// Sample rate getting/setting
- (void)setSampleRateCorrection:(double)correctionPPM
{
	uint8_t tmp;
	int16_t offs = correctionPPM * (-1) * TWO_POW(24) / 1000000;
    
	tmp = offs & 0xff;
//	r |= rtlsdr_demod_write_reg(dev, 1, 0x3f, tmp, 1);
    [self demodWriteValue:tmp AtAddress:0x3f InBlock:1 Length:1];
    
	tmp = (offs >> 8) & 0x3f;
//	r |= rtlsdr_demod_write_reg(dev, 1, 0x3e, tmp, 1);
    [self demodWriteValue:tmp AtAddress:0x3e InBlock:1 Length:1];
}

-(double)sampleRate
{
    return sampleRate;
}

-(double)setSampleRate:(double)newSampleRate
{
    // OSMOCOM RTL-SDR DERIVED CODE
    uint16_t tmp;
	uint32_t rsamp_ratio;
	double real_rate;
        
	/* check for the maximum rate the resampler supports */
	if (newSampleRate > MAX_SAMP_RATE)
		newSampleRate = MAX_SAMP_RATE;
    
	rsamp_ratio = (rtlXtal * pow(2, 22)) / newSampleRate;
	rsamp_ratio &= ~3;
    
	real_rate = (rtlXtal * pow(2, 22)) / rsamp_ratio;
    
	if ( newSampleRate != real_rate )
		NSLog(@"Exact sample rate is: %f Hz\n", real_rate);
    
    [tuner setBandWidth:real_rate];
    
	sampleRate = newSampleRate;
    
	tmp = (rsamp_ratio >> 16);
    [self demodWriteValue:tmp AtAddress:0x9f InBlock:1 Length:2];
//	rtlsdr_demod_write_reg(dev, 1, 0x9f, tmp, 2);

	tmp = rsamp_ratio & 0xffff;
    [self demodWriteValue:tmp AtAddress:0xa1 InBlock:1 Length:2];
//  rtlsdr_demod_write_reg(dev, 1, 0xa1, tmp, 2);
    
    [self setSampleRateCorrection:0];
    
	/* reset demod (bit 3, soft_rst) */
    [self demodWriteValue:0x14 AtAddress:0x01 InBlock:1 Length:1];
//	rtlsdr_demod_write_reg(dev, 1, 0x01, 0x14, 1);

    [self demodWriteValue:0x10 AtAddress:0x01 InBlock:1 Length:1];
//	rtlsdr_demod_write_reg(dev, 1, 0x01, 0x10, 1);    
    // END OSMOCOM CODE
    
    return real_rate;
}

- (double)setCenterFreq:(double)freq
{
    double f = (double)freq * (1.0 + freqCorrection / 1e6);
    return [tuner setFreq:f];
}

- (double)centerFreq
{
    return [tuner freq];
}

-(void)setFreqCorrection:(NSUInteger)newFreqCorrection
{
	if (freqCorrection == newFreqCorrection)
		return;
    
    freqCorrection = newFreqCorrection;
    
	/* retune to apply new correction value */
    [self setCenterFreq:centerFreq];
    
	return;
}

-(NSUInteger)freqCorrection
{
	return freqCorrection;
}

-(void)setTunerGain:(NSUInteger)newTunerGain
{
    [tuner setGain:newTunerGain];
}

-(NSUInteger)tunerGain
{
    return [tuner gain];
}

//int rtlsdr_set_xtal_freq(rtlsdr_dev_t *dev, uint32_t rtl_freq, uint32_t tuner_freq)

- (NSUInteger)rtlFreq
{
    return rtlFreq;
}

- (void)setRtlFreq:(NSUInteger)newRtlFreq
{
    // OSMOCOM RTL-SDR DERIVED CODE
	if (newRtlFreq < MIN_RTL_XTAL_FREQ ||
        newRtlFreq > MAX_RTL_XTAL_FREQ)
		return;
    
	if (rtlXtal != rtlFreq) {
		rtlXtal  = rtlFreq;
        
		if (rtlXtal == 0)
			rtlXtal = DEF_RTL_XTAL_FREQ;
        
		/* update xtal-dependent settings */
        [self setSampleRate:sampleRate];
	}
    
    // END OSMOCOM CODE
}

- (NSUInteger)tunerClock
{
    return tunerClock;
}

// This is probably horribly wrong
- (void)setTunerClock:(NSUInteger)newTunerFreq
{
    // OSMOCOM RTL-SDR DERIVED CODE
	if (newTunerFreq != tunerClock) {
        
		tunerClock = newTunerFreq;
        
		if (tunerClock == 0)
			tunerClock = rtlXtal;
        
		/* update xtal-dependent settings */
        [tuner setFreq:[tuner freq]];
	}
    
    // END O%uM CODE
}

- (float)ifFrequency
{
    return ifFrequency;
}

- (void)setIfFrequency:(float)inFreq
{
    int32_t if_freq;
    uint8_t tmp;
    
    if_freq = ((inFreq * TWO_POW(22)) / rtlXtal) * (-1);
    
    tmp = (if_freq >> 16) & 0x3f;
//    r = rtlsdr_demod_write_reg(dev, 1, 0x19, tmp, 1);
    [self demodWriteValue:tmp AtAddress:0x19 InBlock:1 Length:1];
    
    tmp = (if_freq >> 8) & 0xff;
//    r |= rtlsdr_demod_write_reg(dev, 1, 0x1a, tmp, 1);
    [self demodWriteValue:tmp AtAddress:0x1a InBlock:1 Length:1];

    tmp = if_freq & 0xff;
//    r |= rtlsdr_demod_write_reg(dev, 1, 0x1b, tmp, 1);
    [self demodWriteValue:tmp AtAddress:0x1b InBlock:1 Length:1];
}

#pragma mark -
#pragma mark Bulk data methods
-(bool)resetEndpoints
{
//  rtlsdr_write_reg(dev, USBB, USB_EPA_CTL, 0x1002, 2);
    [self writeValue:0x1002 AtAddress:USB_EPA_CTL InBlock:USBB Length:2];
    
//  rtlsdr_write_reg(dev, USBB, USB_EPA_CTL, 0x0000, 2);
    [self writeValue:0x0000 AtAddress:USB_EPA_CTL InBlock:USBB Length:2];

    return YES;
}


- (NSData *)readSychronousLength:(NSUInteger)length
{
    // Make sure that the length is a multiple of the packet size
    if (length % bulkPacketSize != 0) {
        NSLog(@"Attempted read not of an integer number of packets");
        return nil;
    }
 
    // Create an NSMutableData object
    NSMutableData *tempData = [[NSMutableData alloc] initWithLength:length];
    // Get a reference to the actual bytes
    uint8_t *bytes = [tempData mutableBytes];
    UInt32 size = (UInt32)length;
    
    IOReturn kretval;
    kretval = (*bulkInterface)->ReadPipe(bulkInterface, bulkPipeRef, bytes, &size);

    if (kretval != kIOReturnSuccess)
    {
        int system = err_get_system(kretval);
        int subsys = err_get_sub(kretval);
        int code = err_get_code(kretval);
        
        printf("Unable to perform bulk read (0x%08x): system 0x%x, subsystem 0x%x, code 0x%x.\n", kretval, system, subsys, code);

        (*bulkInterface)->ClearPipeStallBothEnds(bulkInterface, bulkPipeRef);
        kretval = (*bulkInterface)->ReadPipe(bulkInterface, bulkPipeRef, bytes, &size);
        if (kretval != kIOReturnSuccess) {
            printf("Clear pipe stall didn't work\n");

            (*bulkInterface)->ResetPipe(bulkInterface, bulkPipeRef);
            kretval = (*bulkInterface)->ReadPipe(bulkInterface, bulkPipeRef, bytes, &size);
            if (kretval != kIOReturnSuccess) {
                printf("Reset pipe didn't work\n");
                
                [self resetEndpoints];
                kretval = (*bulkInterface)->ReadPipe(bulkInterface, bulkPipeRef, bytes, &size);
                if (kretval != kIOReturnSuccess) {
                    printf("Reset endpoints didn't work, I'm out of options.\n");
                    return nil;
                }
            }
        }
    }
    
    return tempData;
}


typedef struct {
    IOUSBInterfaceInterface220 **bulkInterface;
    int pipeRef;
    
    UInt32 newLength;
    UInt32 length;
    void *bytes;
    
    // Obj-C objects needed for asynchronous operation
    __unsafe_unretained RTLSDRDevice *device;
} context_t;

static context_t firstContext;
static context_t secondContext;

static uint64_t  startTime;
static uint64_t  lastTime;
static uint64_t  totalSamples;

double subtractTimes( uint64_t endTime, uint64_t startTime );
double subtractTimes( uint64_t endTime, uint64_t startTime )
{
	uint64_t difference = endTime - startTime;
	static double conversion = 0.0;
	
	if( conversion == 0.0 )
	{
		mach_timebase_info_data_t info;
		kern_return_t err = mach_timebase_info( &info );
		
		//Convert the timebase into seconds
		if( err == 0  )
			conversion = 1e-9 * (double) info.numer / (double) info.denom;
	}
	
	return conversion * (double) difference;
}

#pragma mark Asynchronous operations
- (RTLSDRAsyncBlock)block
{
    return asyncBlock;
}

@synthesize asyncRunning;
- (bool)stopReading
{
    
    
    return YES;
}

void asyncCallback(void *refcon, IOReturn kretval, void *arg0);

void asyncCallback(void *refcon, IOReturn kretval, void *arg0)
{
    @autoreleasepool {
        context_t *contextPointer = refcon;
        RTLSDRDevice *device = contextPointer->device;
        
        IOUSBInterfaceInterface220 **bulkInterface = contextPointer->bulkInterface;
        int pipeRef = contextPointer->pipeRef;
        
        UInt32 bytesRead = (UInt32)arg0;
        UInt32 length = contextPointer->length;
        void *bytes = contextPointer->bytes;
        
        // Make sure it worked
        if (kretval != kIOReturnSuccess)
        {
            int system = err_get_system(kretval);
            int subsys = err_get_sub(kretval);
            int code = err_get_code(kretval);
            
            printf("Unable to perform async. bulk read (0x%08x): system 0x%x, subsystem 0x%x, code 0x%x.\n",
                   kretval, system, subsys, code);
            
            (*bulkInterface)->ClearPipeStallBothEnds(bulkInterface, pipeRef);
            (*bulkInterface)->ResetPipe(bulkInterface, pipeRef);
            
            // Run the Async command again
            kretval = (*bulkInterface)->ReadPipeAsync(bulkInterface,
                                                      pipeRef,
                                                      bytes, length,
                                                      asyncCallback,
                                                      contextPointer);
            
            if (kretval != kIOReturnSuccess) {
                printf("Reset endpoints didn't work, I'm out of options.\n");
                [device stopReading];
            }
            
            return;
        }
        
        totalSamples += bytesRead / 2;
        
        //    double deltaTime = subtractTimes(mach_absolute_time(), startTime);
        //    double rate = totalSamples / deltaTime;
        uint64_t thisTime = mach_absolute_time();
        double deltaTime = subtractTimes(thisTime, lastTime);
        lastTime = thisTime;
        
        double rate = (float)(bytesRead / 2) / deltaTime;
        
        if (COCOARADIODEVICE_ASYNCCALLBACK_ENABLED()) {
            int context = 1;
            if (&secondContext == contextPointer) {
                context = 2;
            }
            COCOARADIODEVICE_ASYNCCALLBACK(context, (int)rate);
        }
        
        device.realSampleRate = rate;
        
        // It's probably not wise to execute blocks if stopped
        if([device asyncRunning]) {
            [device block]([NSData dataWithBytes:bytes length:bytesRead], deltaTime);
            
            // run it again, sam!
            // Adjust the data size if neccessary
            if (contextPointer->newLength != 0 &&
                contextPointer->newLength != contextPointer->length) {
                contextPointer->bytes = realloc(contextPointer->bytes,
                                                contextPointer->newLength);
                contextPointer->length = contextPointer->newLength;
                contextPointer->newLength = 0;
                bytes = contextPointer->bytes;
            }
            
            // Run the Async command again
            kretval = (*bulkInterface)->ReadPipeAsync(bulkInterface,
                                                      pipeRef,
                                                      bytes, length,
                                                      asyncCallback,
                                                      contextPointer);
            
            // Check for errors
            if (kretval != kIOReturnSuccess)
            {
                int system = err_get_system(kretval);
                int subsys = err_get_sub(kretval);
                int code = err_get_code(kretval);
                
                printf("Unable to perform asynchronous bulk read (0x%08x): system 0x%x, subsystem 0x%x, code 0x%x.\n",
                       kretval, system, subsys, code);
                
                [device stopReading];
            }
        }
    }
}

- (void)asyncLoop
{
    // Allow this thread to execute with maximum priority
    [NSThread setThreadPriority:1.];

    @autoreleasepool {
        CFRunLoopRef cfRunLoop = [[NSRunLoop currentRunLoop] getCFRunLoop];
        CFRunLoopAddSource(cfRunLoop, runLoopSource,
                           kCFRunLoopDefaultMode);
        [[NSRunLoop currentRunLoop] run];
        
        // We should never get here
        NSLog(@"The async run loop exited!");
        exit(EXIT_FAILURE);
    }
}

-(void)readAsynchLength:(NSUInteger)length
              withBlock:(RTLSDRAsyncBlock)inBlock
{
    IOReturn kretval;

// Do all the same checking as readSync
    // Make sure that the length is a multiple of the packet size
    if (length % bulkPacketSize != 0) {
        NSLog(@"Attempted read not of an integer number of packets");
        return;
    }

    // If we're already running, change the response block
    if (asyncRunning) {
        asyncBlock = inBlock;

        // Change the data length if necessary
        if (length != firstContext.length) {
            firstContext.newLength = (UInt32)length;
        }
        if (length != secondContext.length) {
            secondContext.newLength = (UInt32)length;
        }
        return;
    } else {
        asyncRunning = true;
    }
    
    // Create an event source for asynchronous operations
    kretval = (*bulkInterface)->CreateInterfaceAsyncEventSource(bulkInterface,
                                                                &runLoopSource);

    
    if (kretval != kIOReturnSuccess) {
        int system = err_get_system(kretval);
        int subsys = err_get_sub(kretval);
        int code   = err_get_code(kretval);
        
        printf("Unable to create the asynchronous event source (0x%08x): system 0x%x, subsystem 0x%x, code 0x%x.\n",
               kretval, system, subsys, code);
        return;
    }

    // Add the run loop source to the run loop
//    CFRunLoopRef CFRunLoop = [[NSRunLoop currentRunLoop] getCFRunLoop];
//    CFRunLoopAddSource(CFRunLoop, runLoopSource,
//                       kCFRunLoopDefaultMode);

    // Create a new NSThread with this event source
    asyncThread = [[NSThread alloc] initWithTarget:self
                                          selector:@selector(asyncLoop)
                                            object:nil];
    [asyncThread start];
    
//    NSLog(@"Added asynchronous event source");
    
    asyncBlock = inBlock;
    firstContext.device = self;
    firstContext.length = (UInt32)length;
    firstContext.bytes = malloc(length);
    firstContext.bulkInterface = bulkInterface;
    firstContext.pipeRef = bulkPipeRef;
    
    (*bulkInterface)->ClearPipeStallBothEnds(bulkInterface, bulkPipeRef);
    (*bulkInterface)->ResetPipe(bulkInterface, bulkPipeRef);
    [self resetEndpoints];
    
    kretval = (*bulkInterface)->ReadPipeAsync(bulkInterface,
                                              bulkPipeRef,
                                              firstContext.bytes,
                                              firstContext.length,
                                              asyncCallback,
                                              &firstContext);

    startTime = mach_absolute_time();
    
    if (kretval != kIOReturnSuccess)
    {
        int system = err_get_system(kretval);
        int subsys = err_get_sub(kretval);
        int code = err_get_code(kretval);
        
        printf("Unable to perform bulk read (0x%08x): system 0x%x, subsystem 0x%x, code 0x%x.\n",
               kretval, system, subsys, code);
        return;
    }
    
    // We want to have 2 asynchronous operations going at all times
    // this means that we'll immediately start another.
    secondContext.device = self;
    secondContext.length = (UInt32)length;
    secondContext.bytes = malloc(length);
    secondContext.bulkInterface = bulkInterface;
    secondContext.pipeRef = bulkPipeRef;

    if (secondContext.bytes == NULL) {
        printf("Unable to allocate bytes for the second async context");
        return;
    }
    
    kretval = (*bulkInterface)->ReadPipeAsync(bulkInterface,
                                              bulkPipeRef,
                                              firstContext.bytes,
                                              firstContext.length,
                                              asyncCallback,
                                              &secondContext);
    
    if (kretval != kIOReturnSuccess)
    {
        int system = err_get_system(kretval);
        int subsys = err_get_sub(kretval);
        int code = err_get_code(kretval);
        
        printf("Unable to perform bulk read (0x%08x): system 0x%x, subsystem 0x%x, code 0x%x.\n",
               kretval, system, subsys, code);
        return;
    }
}

- (void)stop
{
    asyncRunning = NO;
    asyncBlock = nil;
    free(firstContext.bytes);
    free(secondContext.bytes);
}

@end
