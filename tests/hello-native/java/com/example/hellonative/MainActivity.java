package com.example.hellonative;

import android.app.Activity;
import android.os.Bundle;
import android.util.Log;
import android.widget.TextView;

public class MainActivity extends Activity {
    public static final String TAG = "hello-native";

    static { System.loadLibrary("hellonative"); }

    private native String stringFromNative();
    private native int addNative(int a, int b);

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        String s = stringFromNative();
        int sum = addNative(20, 22);

        // 打到 logcat，好让 tests/hello-native/build.sh --install 自动判定成败。
        // 只看「装上了」不算数——要看原生代码真的被调用并算对了。
        Log.i(TAG, "RESULT " + s + " | 20+22=" + sum);

        TextView tv = new TextView(this);
        tv.setText(s + "\n20 + 22 = " + sum);
        setContentView(tv);
    }
}
