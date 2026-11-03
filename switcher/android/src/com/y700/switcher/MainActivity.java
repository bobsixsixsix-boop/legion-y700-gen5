package com.y700.switcher;

import android.app.Activity;
import android.app.AlertDialog;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.util.TypedValue;
import android.view.Gravity;
import android.view.MotionEvent;
import android.view.View;
import android.view.animation.PathInterpolator;
import android.widget.Button;
import android.widget.LinearLayout;
import android.widget.ScrollView;
import android.widget.TextView;

import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.util.HashMap;
import java.util.Map;

/** One screen: status, one button, a confirmation, the live output of the switch script. */
public class MainActivity extends Activity {
    private static final String DIR = "/data/adb/y700";
    private static final PathInterpolator EASE_OUT = new PathInterpolator(0.23f, 1f, 0.32f, 1f);

    private final Handler ui = new Handler(Looper.getMainLooper());
    private TextView status;
    private TextView log;
    private ScrollView logScroll;
    private Button go;
    private boolean ready;

    private int dp(float v) {
        return Math.round(TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v, getResources().getDisplayMetrics()));
    }

    @Override
    protected void onCreate(Bundle b) {
        super.onCreate(b);
        boolean dark = (getResources().getConfiguration().uiMode & android.content.res.Configuration.UI_MODE_NIGHT_MASK)
                == android.content.res.Configuration.UI_MODE_NIGHT_YES;
        int bg = dark ? 0xFF121212 : 0xFFF7F7F5;
        int fg = dark ? 0xFFEDEDED : 0xFF1A1A1A;
        int sub = dark ? 0xFF9A9A9A : 0xFF6B6B6B;
        int panel = dark ? 0xFF1C1C1C : 0xFFFFFFFF;
        int accent = 0xFF2F6FEB;

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setBackgroundColor(bg);
        root.setPadding(dp(32), dp(40), dp(32), dp(24));

        TextView title = new TextView(this);
        title.setText("切换到 Linux");
        title.setTextColor(fg);
        title.setTextSize(28);
        title.setTypeface(Typeface.create("sans-serif-medium", Typeface.NORMAL));
        root.addView(title);

        TextView hint = new TextView(this);
        hint.setText("写入 Linux 启动镜像并重启。回安卓：在 Linux 里打开“切换到 Android”。");
        hint.setTextColor(sub);
        hint.setTextSize(14);
        hint.setPadding(0, dp(8), 0, dp(24));
        root.addView(hint);

        status = new TextView(this);
        status.setTextColor(fg);
        status.setTextSize(15);
        status.setLineSpacing(dp(4), 1f);
        status.setText("正在读取状态…");
        root.addView(status);

        go = new Button(this);
        go.setAllCaps(false);
        go.setText("切换到 Linux");
        go.setTextSize(17);
        go.setTextColor(Color.WHITE);
        GradientDrawable shape = new GradientDrawable();
        shape.setColor(accent);
        shape.setCornerRadius(dp(6));
        go.setBackground(shape);
        go.setStateListAnimator(null);
        LinearLayout.LayoutParams lp = new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, dp(56));
        lp.topMargin = dp(28);
        lp.bottomMargin = dp(20);
        root.addView(go, lp);
        go.setEnabled(false);
        go.setAlpha(0.5f);
        go.setOnTouchListener((v, e) -> {
            if (!v.isEnabled()) return false;
            if (e.getAction() == MotionEvent.ACTION_DOWN) {
                v.animate().scaleX(0.97f).scaleY(0.97f).setDuration(160).setInterpolator(EASE_OUT).start();
            } else if (e.getAction() == MotionEvent.ACTION_UP || e.getAction() == MotionEvent.ACTION_CANCEL) {
                v.animate().scaleX(1f).scaleY(1f).setDuration(160).setInterpolator(EASE_OUT).start();
            }
            return false;
        });
        go.setOnClickListener(v -> confirm());

        logScroll = new ScrollView(this);
        GradientDrawable lb = new GradientDrawable();
        lb.setColor(panel);
        lb.setCornerRadius(dp(6));
        logScroll.setBackground(lb);
        log = new TextView(this);
        log.setTypeface(Typeface.MONOSPACE);
        log.setTextSize(12);
        log.setTextColor(sub);
        log.setPadding(dp(14), dp(12), dp(14), dp(12));
        logScroll.addView(log);
        root.addView(logScroll, new LinearLayout.LayoutParams(LinearLayout.LayoutParams.MATCH_PARENT, 0, 1f));

        setContentView(root);
        refresh();
    }

    private void refresh() {
        new Thread(() -> {
            Map<String, String> s = new HashMap<>();
            StringBuilder raw = new StringBuilder();
            int rc = run("sh " + DIR + "/status.sh", line -> {
                raw.append(line).append('\n');
                int i = line.indexOf('=');
                if (i > 0) s.put(line.substring(0, i), line.substring(i + 1));
            });
            ui.post(() -> showStatus(rc, s, raw.toString()));
        }).start();
    }

    private void showStatus(int rc, Map<String, String> s, String raw) {
        if (rc != 0 || s.isEmpty()) {
            status.setText("没有 root 权限，或切换脚本未安装。\n请在 KernelSU 的“超级用户”里允许本应用，然后重新打开。");
            ready = false;
        } else {
            String a = s.get("boot_a");
            String now = "android".equals(a) ? "安卓" : "linux".equals(a) ? "Linux（下次重启进 Linux）" : "未知镜像";
            boolean bOk = "yes".equals(s.get("boot_b_ok"));
            String staged = s.get("staged");
            status.setText("当前 boot_a：" + now
                    + "\n回安卓的备份（boot_b）：" + (bOk ? "正常" : "不对，已禁止切换")
                    + "\n备用镜像（暂存）：" + ("none".equals(staged) ? "没有" : staged));
            // The switch script picks the image: the last running Linux (linux-current/linux-good.img on the Linux
            // root) first, the staged one only as a fallback; with none at all it stops before writing. So the
            // staged image must not gate the button (10-31 audit misc A3).
            ready = bOk && !"linux".equals(a);
        }
        go.setEnabled(ready);
        go.animate().alpha(ready ? 1f : 0.5f).setDuration(160).setInterpolator(EASE_OUT).start();
        if (!raw.isEmpty()) log.setText(raw);
    }

    private void confirm() {
        new AlertDialog.Builder(this)
                .setTitle("切换到 Linux？")
                .setMessage("会把 Linux 启动镜像写进 boot_a，核对无误后立即重启。正在运行的应用会被关闭。")
                .setNegativeButton("取消", null)
                .setPositiveButton("切换并重启", (d, w) -> doSwitch())
                .show();
    }

    private void doSwitch() {
        go.setEnabled(false);
        go.setText("正在切换…");
        log.setText("");
        new Thread(() -> {
            int rc = run("sh " + DIR + "/switch-to-linux.sh", line -> ui.post(() -> {
                log.append(line + "\n");
                logScroll.post(() -> logScroll.fullScroll(View.FOCUS_DOWN));
            }));
            ui.post(() -> {
                if (rc != 0) {
                    go.setText("切换到 Linux");
                    log.append("\n已停止，仍在安卓。\n");
                    refresh();
                } else {
                    go.setText("正在重启…");
                }
            });
        }).start();
    }

    interface Line { void on(String line); }

    private static int run(String cmd, Line out) {
        try {
            Process p = new ProcessBuilder("su", "-c", cmd + " 2>&1").redirectErrorStream(true).start();
            try (BufferedReader r = new BufferedReader(new InputStreamReader(p.getInputStream()))) {
                String l;
                while ((l = r.readLine()) != null) out.on(l);
            }
            return p.waitFor();
        } catch (Exception e) {
            out.on("! " + e.getMessage());
            return -1;
        }
    }
}
