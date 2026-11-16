package de.trainerbank.app;

import android.annotation.SuppressLint;
import android.app.Activity;
import android.content.Intent;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.view.ViewGroup;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.FrameLayout;

import androidx.activity.ComponentActivity;
import androidx.activity.OnBackPressedCallback;
import androidx.activity.result.ActivityResultLauncher;
import androidx.activity.result.contract.ActivityResultContracts;
import androidx.core.graphics.Insets;
import androidx.core.view.ViewCompat;
import androidx.core.view.WindowInsetsCompat;

import java.io.OutputStream;
import java.nio.charset.StandardCharsets;

/**
 * Schlanke Hülle um das Spiel: Die HTML-Datei liegt in der App (assets/index.html)
 * und läuft in einem WebView. Es gibt keinen Netzwerkzugriff.
 */
public class MainActivity extends ComponentActivity {

    private static final String START_URL = "file:///android_asset/index.html";
    private static final int BG = Color.parseColor("#0F5A54");

    private WebView web;
    private ValueCallback<Uri[]> pendingChooser;
    private String pendingSave;

    private ActivityResultLauncher<Intent> pickFile;
    private ActivityResultLauncher<Intent> createFile;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        // Datei auswählen (Spielstand laden, eigene Daten laden)
        pickFile = registerForActivityResult(new ActivityResultContracts.StartActivityForResult(), result -> {
            if (pendingChooser == null) return;
            Uri[] uris = null;
            if (result.getResultCode() == Activity.RESULT_OK && result.getData() != null) {
                uris = WebChromeClient.FileChooserParams.parseResult(result.getResultCode(), result.getData());
            }
            pendingChooser.onReceiveValue(uris);
            pendingChooser = null;
        });

        // Datei anlegen (Spielstand sichern)
        createFile = registerForActivityResult(new ActivityResultContracts.StartActivityForResult(), result -> {
            boolean ok = false;
            String data = pendingSave;
            pendingSave = null;
            if (result.getResultCode() == Activity.RESULT_OK && result.getData() != null
                    && result.getData().getData() != null && data != null) {
                try (OutputStream os = getContentResolver().openOutputStream(result.getData().getData())) {
                    if (os != null) {
                        os.write(data.getBytes(StandardCharsets.UTF_8));
                        ok = true;
                    }
                } catch (Exception ignored) {
                    ok = false;
                }
            }
            final boolean done = ok;
            web.post(() -> web.evaluateJavascript("window.tbSaved&&window.tbSaved(" + done + ")", null));
        });

        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(BG);
        web = new WebView(this);
        web.setBackgroundColor(BG);
        root.addView(web, new FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT));
        setContentView(root);

        // Inhalt nicht unter Statusleiste, Navigationsleiste oder Tastatur schieben
        ViewCompat.setOnApplyWindowInsetsListener(root, (v, insets) -> {
            Insets bars = insets.getInsets(WindowInsetsCompat.Type.systemBars()
                    | WindowInsetsCompat.Type.displayCutout() | WindowInsetsCompat.Type.ime());
            v.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            return WindowInsetsCompat.CONSUMED;
        });

        WebSettings s = web.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);          // Spielstand (localStorage)
        s.setDatabaseEnabled(true);            // Sicherungskopie (IndexedDB)
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setTextZoom(100);                    // Systemschriftgröße soll das Layout nicht sprengen
        s.setSupportZoom(false);
        s.setBuiltInZoomControls(false);
        s.setAllowFileAccess(true);            // nur für die mitgelieferte Spieldatei
        s.setAllowContentAccess(false);
        s.setCacheMode(WebSettings.LOAD_NO_CACHE);
        web.setOverScrollMode(WebView.OVER_SCROLL_NEVER);
        web.setLongClickable(false);
        web.setHapticFeedbackEnabled(false);

        web.addJavascriptInterface(new Bridge(), "TBApp");

        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                // Die App bleibt bei der eigenen Spieldatei; alles andere wird nicht geladen.
                return !START_URL.equals(request.getUrl().toString());
            }
        });

        web.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onShowFileChooser(WebView view, ValueCallback<Uri[]> callback, FileChooserParams params) {
                if (pendingChooser != null) pendingChooser.onReceiveValue(null);
                pendingChooser = callback;
                try {
                    Intent i = new Intent(Intent.ACTION_GET_CONTENT);
                    i.addCategory(Intent.CATEGORY_OPENABLE);
                    i.setType("*/*");
                    pickFile.launch(i);
                } catch (Exception e) {
                    pendingChooser = null;
                    callback.onReceiveValue(null);
                }
                return true;
            }
        });

        // Zurück-Taste: erst im Spiel einen Schritt zurück, sonst App in den Hintergrund
        getOnBackPressedDispatcher().addCallback(this, new OnBackPressedCallback(true) {
            @Override
            public void handleOnBackPressed() {
                web.evaluateJavascript("(window.tbBack&&window.tbBack())?1:0", value -> {
                    if (!"1".equals(value)) moveTaskToBack(true);
                });
            }
        });

        if (savedInstanceState != null) {
            web.restoreState(savedInstanceState);
        } else {
            web.loadUrl(START_URL);
        }
    }

    @Override
    protected void onSaveInstanceState(Bundle outState) {
        super.onSaveInstanceState(outState);
        web.saveState(outState);
    }

    @Override
    protected void onPause() {
        super.onPause();
        web.onPause();   // hält Ton und Animationen an
    }

    @Override
    protected void onResume() {
        super.onResume();
        web.onResume();
    }

    @Override
    protected void onDestroy() {
        if (web != null) {
            ((ViewGroup) web.getParent()).removeView(web);
            web.destroy();
        }
        super.onDestroy();
    }

    /** Brücke zum Spiel: window.TBApp */
    private class Bridge {
        @JavascriptInterface
        public void saveFile(String name, String json) {
            pendingSave = json;
            runOnUiThread(() -> {
                try {
                    Intent i = new Intent(Intent.ACTION_CREATE_DOCUMENT);
                    i.addCategory(Intent.CATEGORY_OPENABLE);
                    i.setType("application/json");
                    i.putExtra(Intent.EXTRA_TITLE, name);
                    createFile.launch(i);
                } catch (Exception e) {
                    pendingSave = null;
                    web.evaluateJavascript("window.tbSaved&&window.tbSaved(false)", null);
                }
            });
        }
    }
}
