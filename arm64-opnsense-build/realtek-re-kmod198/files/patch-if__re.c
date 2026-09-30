--- if_re.c.orig	2024-06-04 09:39:04 UTC
+++ if_re.c
@@ -2895,7 +2895,8 @@ static int re_check_mac_version(struct re_softc *sc)
                 CSR_WRITE_4(sc, RE_RXCFG, 0x40C00800);
                 break;
         default:
-                device_printf(dev,"unknown device\n");
+                device_printf(dev, "unknown device: TXCFG=0x%08x\n",
+                    CSR_READ_4(sc, RE_TXCFG));
                 sc->re_type = MACFG_FF;
                 error = ENXIO;
                 break;
