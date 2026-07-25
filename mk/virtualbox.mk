# Configuration file for VirtualBox, it creates a VirtualBox virtual machine

virtualbox: $(BUILD)/harddrive.img
	echo "Delete VM"
	-$(VBM) unregistervm FlashOS --delete; \
	if [ $$? -ne 0 ]; \
	then \
		if [ -d "$$HOME/VirtualBox VMs/FlashOS" ]; \
		then \
			echo "FlashOS directory exists, deleting..."; \
			$(RM) -rf "$$HOME/VirtualBox VMs/FlashOS"; \
		fi \
	fi
	echo "Delete Disk"
	-$(RM) harddrive.vdi
	echo "Create VM"
	$(VBM) createvm --name FlashOS --register
	echo "Set Configuration"
	$(VBM) modifyvm FlashOS --memory 2048
	$(VBM) modifyvm FlashOS --vram 32
	if [ "$(net)" != "no" ]; \
	then \
		$(VBM) modifyvm FlashOS --nic1 nat; \
		$(VBM) modifyvm FlashOS --nictype1 82540EM; \
		$(VBM) modifyvm FlashOS --cableconnected1 on; \
		$(VBM) modifyvm FlashOS --nictrace1 on; \
		$(VBM) modifyvm FlashOS --nictracefile1 "$(ROOT)/$(BUILD)/network.pcap"; \
	fi
	$(VBM) modifyvm FlashOS --uart1 0x3F8 4
	$(VBM) modifyvm FlashOS --uartmode1 file "$(ROOT)/$(BUILD)/serial.log"
	$(VBM) modifyvm FlashOS --usb off # on
	$(VBM) modifyvm FlashOS --keyboard ps2
	$(VBM) modifyvm FlashOS --mouse ps2
	$(VBM) modifyvm FlashOS --audio-driver $(VB_AUDIO)
	$(VBM) modifyvm FlashOS --audiocontroller hda
	$(VBM) modifyvm FlashOS --audioout on
	$(VBM) modifyvm FlashOS --nestedpaging on
	echo "Create Disk"
	$(VBM) convertfromraw $< $(BUILD)/harddrive.vdi
	echo "Attach Disk"
	$(VBM) storagectl FlashOS --name ATA --add sata --controller IntelAHCI --bootable on --portcount 1
	$(VBM) storageattach FlashOS --storagectl ATA --port 0 --device 0 --type hdd --medium $(BUILD)/harddrive.vdi
	echo "Run VM"
	$(VBM) startvm FlashOS
