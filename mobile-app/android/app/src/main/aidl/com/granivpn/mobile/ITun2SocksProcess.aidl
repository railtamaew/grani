package com.granivpn.mobile;

import android.os.ParcelFileDescriptor;

interface ITun2SocksProcess {
    void startTun2Socks(in ParcelFileDescriptor tunFd, int mtu, in String socksAddress, int socksPort);
    void stopTun2Socks(in String source, in String reason, boolean confirmedStopVpn);
    boolean isTun2SocksRunning();
}
