package com.example.chatapp;

import android.os.Bundle;
import android.view.WindowManager;
import io.flutter.embedding.android.FlutterActivity;

public class MainActivity extends FlutterActivity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        // Prevent OS from capturing a screenshot for the recents thumbnail
        getWindow().addFlags(WindowManager.LayoutParams.FLAG_SECURE);
    }
}
