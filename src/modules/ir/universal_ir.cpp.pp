#include "universal_ir.h"
#include "core/display.h"
#include "core/mykeyboard.h"
#include "core/sd_functions.h"
#include "core/settings.h"
#include "modules/ir/TV-B-Gone.h"
#include "modules/ir/ir_utils.h"
#include <vector>
#include <algorithm>

#define UNIVERSAL_IR_FOLDER "/Bruceir"

struct UniversalButton {
    String name;
    std::vector<IRCode*> codes;
};

static std::vector<UniversalButton> universalButtons;

void resetUniversalButtons() {
    for (auto& btn : universalButtons) {
        for (auto code : btn.codes) delete code;
        btn.codes.clear();
    }
    universalButtons.clear();
}

std::vector<String> scanUniversalDevices(FS& fs) {
    std::vector<String> devices;
    File root = fs.open(UNIVERSAL_IR_FOLDER);
    if (!root || !root.isDirectory()) {
        fs.mkdir(UNIVERSAL_IR_FOLDER);
        return devices;
    }
    File file = root.openNextFile();
    while (file) {
        String name = String(file.name());
        int lastSlash = name.lastIndexOf('/');
        if (lastSlash >= 0) name = name.substring(lastSlash + 1);
        if (!file.isDirectory() && name.endsWith(".ir")) {
            name = name.substring(0, name.lastIndexOf(".ir"));
            devices.push_back(name);
        }
        file.close();
        file = root.openNextFile();
    }
    root.close();
    return devices;
}

bool loadUniversalIRFile(FS& fs, String filename) {
    resetUniversalButtons();
    String filepath = String(UNIVERSAL_IR_FOLDER) + "/" + filename + ".ir";
    File databaseFile = fs.open(filepath, FILE_READ);
    if (!databaseFile) return false;

    String line, txt;
    IRCode* currentCode = nullptr;
    String currentButtonName = "";

    while (databaseFile.available()) {
        line = databaseFile.readStringUntil('\n');
        line.trim();
        txt = line.substring(line.indexOf(":") + 1);
        txt.trim();
        if (line.startsWith("name:")) {
            if (currentCode != nullptr && currentButtonName != "") {
                bool found = false;
                for (auto& btn : universalButtons) {
                    if (btn.name == currentButtonName) {
                        btn.codes.push_back(currentCode);
                        found = true;
                        break;
                    }
                }
                if (!found) {
                    UniversalButton ub;
                    ub.name = currentButtonName;
                    ub.codes.push_back(currentCode);
                    universalButtons.push_back(ub);
                }
                currentCode = nullptr;
            }
            currentButtonName = txt;
            currentCode = new IRCode();
            currentCode->name = txt;
            currentCode->filepath = filename + "/" + txt;
        }
        else if (line.startsWith("type:") && currentCode != nullptr) currentCode->type = txt;
        else if (line.startsWith("protocol:") && currentCode != nullptr) currentCode->protocol = txt;
        else if (line.startsWith("address:") && currentCode != nullptr) currentCode->address = txt;
        else if (line.startsWith("command:") && currentCode != nullptr) currentCode->command = txt;
        else if (line.startsWith("frequency:") && currentCode != nullptr) currentCode->frequency = txt.toInt();
        else if (line.startsWith("bits:") && currentCode != nullptr) currentCode->bits = txt.toInt();
        else if (line.startsWith("data:") || line.startsWith("value:") || line.startsWith("state:")) {
            if (currentCode != nullptr) currentCode->data = txt;
        }
        else if (line.startsWith("#") && currentCode != nullptr && currentButtonName != "") {
            bool found = false;
            for (auto& btn : universalButtons) {
                if (btn.name == currentButtonName) {
                    btn.codes.push_back(currentCode);
                    found = true;
                    break;
                }
            }
            if (!found) {
                UniversalButton ub;
                ub.name = currentButtonName;
                ub.codes.push_back(currentCode);
                universalButtons.push_back(ub);
            }
            currentCode = new IRCode();
            currentCode->name = currentButtonName;
            currentCode->filepath = filename + "/" + currentButtonName;
        }
    }
    if (currentCode != nullptr && currentButtonName != "") {
        bool found = false;
        for (auto& btn : universalButtons) {
            if (btn.name == currentButtonName) {
                btn.codes.push_back(currentCode);
                found = true;
                break;
            }
        }
        if (!found) {
            UniversalButton ub;
            ub.name = currentButtonName;
            ub.codes.push_back(currentCode);
            universalButtons.push_back(ub);
        }
    } else if (currentCode != nullptr) delete currentCode;
    databaseFile.close();
    return true;
}

void sendUniversalCommand(String buttonName) {
    checkIrTxPin();
    setup_ir_pin(bruceConfigPins.irTx, OUTPUT);
    for (auto& btn : universalButtons) {
        if (btn.name == buttonName) {
            displayTextLine(("Sending " + buttonName + "...").c_str());
            int total = btn.codes.size();
            for (int i = 0; i < total; i++) {
                sendIRCommand(btn.codes[i], true);
                delay(50);
            }
            displayTextLine(("Sent " + buttonName + " (" + String(total) + " variants)").c_str());
            delay(500);
            return;
        }
    }
    displayTextLine(("No codes for " + buttonName).c_str());
    delay(1000);
}

void universalRemoteMenu(FS& fs) {
    checkIrTxPin();
    auto devices = scanUniversalDevices(fs);
    if (devices.empty()) {
        displayTextLine("No .ir files in /Bruceir");
        delay(2000);
        return;
    }
    std::sort(devices.begin(), devices.end());
    options = {};
    bool exit = false;
    for (auto& dev : devices) {
        String devName = dev;
        options.push_back({devName.c_str(), [&fs, devName]() {
            if (!loadUniversalIRFile(fs, devName)) {
                displayTextLine("Failed to load " + devName);
                delay(1500);
                return;
            }
            options = {};
            bool back = false;
            std::vector<String> stdButtons = {
                "POWER","SOURCE","INPUT","UP","DOWN","LEFT","RIGHT","OK",
                "VOL+","VOL-","CH+","CH-","MUTE","MENU","EXIT","BACK",
                "0","1","2","3","4","5","6","7","8","9"
            };
            for (auto& stdBtn : stdButtons) {
                for (auto& btn : universalButtons) {
                    if (btn.name == stdBtn) {
                        String btnName = btn.name;
                        options.push_back({(btnName+" ["+String(btn.codes.size())+"]").c_str(),[btnName](){sendUniversalCommand(btnName);}});
                        break;
                    }
                }
            }
            for (auto& btn : universalButtons) {
                bool isStd = false;
                for (auto& s : stdButtons) { if (btn.name == s) { isStd = true; break; } }
                if (!isStd) {
                    String btnName = btn.name;
                    options.push_back({btnName.c_str(), [btnName](){sendUniversalCommand(btnName);}});
                }
            }
            options.push_back({"Spam All", [&back]() {
                for (auto& btn : universalButtons) { sendUniversalCommand(btn.name); delay(100); if (check(EscPress)) break; }
            }});
            options.push_back({"Back", [&back]() { back = true; }});
            int idx = 0;
            while (1) { idx = loopOptions(options, idx); if (check(EscPress) || back) break; }
            options.clear();
            resetUniversalButtons();
        }});
    }
    options.push_back({"Main Menu", [&exit]() { exit = true; }});
    int idx = 0;
    while (1) {
        idx = loopOptions(options, idx, ("Universal Remote (" + String(devices.size()) + " devices)").c_str());
        if (check(EscPress) || exit) break;
    }
    options.clear();
}