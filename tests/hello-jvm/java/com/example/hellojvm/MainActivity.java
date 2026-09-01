package com.example.hellojvm;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

// 这个 Activity 里每一处 R.xxx 都是故意的：只有 aapt2 link 真的生成了 R.java、
// javac 真的编了它、资源真的进了 APK，这些引用才能在运行时解析成功。
// 少任何一环，装上之后会崩在 Resources$NotFoundException 或者根本编不过。
public class MainActivity extends Activity {
    public static final String TAG = "hello-jvm";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.main);

        String greeting = getString(R.string.greeting);
        String[] items  = getResources().getStringArray(R.array.items);
        // getColor(int) 从 API 23 起废弃，双参版本要 API 23+。这个工程的
        // minSdk 是 21，所以用废弃的这个才是对的——javac 那句 deprecated
        // 提示是预期内的，不是疏忽。
        int color       = getResources().getColor(R.color.accent);

        StringBuilder sb = new StringBuilder();
        for (String s : items) sb.append(s);
        String joined = sb.toString();

        TextView tv = findViewById(R.id.message);
        tv.setText(greeting + "\nitems = " + joined
                 + "\ncolor = #" + Integer.toHexString(color));

        Log.i(TAG, "RESULT " + greeting + " | items=" + joined
                 + " | color=" + Integer.toHexString(color));
    }
}
