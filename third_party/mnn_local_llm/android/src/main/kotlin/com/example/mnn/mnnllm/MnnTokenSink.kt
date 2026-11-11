package com.example.mnn.mnnllm

/** Receives incremental token text from the native generation loop. */
fun interface MnnTokenSink {
    fun onToken(token: String)
}
