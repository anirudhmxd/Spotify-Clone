package com.example.rhythm

import com.ryanheise.audioservice.AudioServiceActivity

// Retain the audio service's shared engine when the app leaves the foreground.
class MainActivity : AudioServiceActivity()
