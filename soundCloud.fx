texture tex : WAVEFORMDATA;

sampler sTex = sampler_state
{
	Texture = (tex);
	MipFilter = LINEAR;
	MinFilter = LINEAR;
	MagFilter = LINEAR;
	AddressU = Clamp;
};

struct VS_IN
{
	float2 pos : POSITION;
	float2 tc : TEXCOORD0;
};

struct PS_IN
{
	float4 pos : SV_POSITION;
	float2 tc : TEXCOORD0;
};

float4 panelBackgroundColor : BACKGROUNDCOLOR; // 'Background color' - whole panel background
float4 waveHighlightColor   : HIGHLIGHTCOLOR;  // 'Highlight color' - for played part
float4 selectionColor       : SELECTIONCOLOR;  // Not used
float4 waveUnplayedColor    : TEXTCOLOR;       // 'Foreground color' - for unplayed part
float cursorPos             : CURSORPOSITION;
bool cursorVisible          : CURSORVISIBLE;
float seekPos               : SEEKPOSITION;
bool seeking                : SEEKING;
float4 replayGain           : REPLAYGAIN;
float2 viewportSize         : VIEWPORTSIZE;
bool horizontal             : ORIENTATION;
bool flipped                : FLIPPED;
bool shadePlayed            : SHADEPLAYED;

float4 colorDodge(float4 baseColor, float4 blendColor)
{
	return saturate(baseColor / (1 - blendColor));
}

float4 linearDodge(float4 baseColor, float4 blendColor)
{
	return saturate(baseColor + blendColor);
}

float4 multiply(float4 baseColor, float4 blendColor)
{
	return saturate(baseColor * blendColor);
}

float4 getSeekAheadColor()
{
	float4 color = colorDodge(waveHighlightColor, 0.4);
	color.a = 0.5;

	return color;
}

float4 getSeekBackColor()
{
	return float4(1.0, 1.0, 1.0, 0.5);
}

float4 getWaveTopColor()
{
	return colorDodge(waveHighlightColor, 0.57);
}

float4 getReflectionHightlightColor()
{
	float4 color = waveHighlightColor;
	color = multiply(color, 0.75);
	color = linearDodge(color, 0.6);

	return color;
}

float2 getPixelSize()
{
	float2 pixelSize = horizontal
		? 1 / viewportSize.xy
		: 1 / viewportSize.yx;

	return pixelSize;
}

/*
  Split waveform into bars.

  Waveform texture contains upper half-waves (positive peaks) in Green channel
  and negative ones in Red. Negative values are ignored to make reflection later.
*/
float4 rmsSampling(float2 tc, float2 pixelSize, inout bool isGap)
{
	float rmsData;
	float mainAxisLength = (horizontal ? viewportSize.x : viewportSize.y);

	if (ceil(mainAxisLength * tc.x) % 3 < 0.1)
	{
		rmsData = tex1D(sTex, tc.x).g;
	}
	else if (ceil(mainAxisLength * tc.x) % 3 < 1.1)
	{
		rmsData = tex1D(sTex, tc.x - pixelSize.x).g;
	}
	else
	{
		isGap = true;

		// Height of a gap equals to height of the smallest neighbour bar
		float leftPeak = tex1D(sTex, tc.x - (2 * pixelSize.x)).g;
		float rightPeak = tex1D(sTex, tc.x + pixelSize.x).g;
		rmsData = min(leftPeak, rightPeak);
	}

	return rmsData;
}

float4 getWaveColor(float2 tc, float2 pixelSize, int pixelBar, int cursorBar, float barCoverage, float4 bgColor, bool isGap)
{
	bool isBeyondSeek = tc.x > seekPos;
	float4 seekAheadColor = getSeekAheadColor();
	float4 seekBackColor = getSeekBackColor();
	float4 seekColor = isBeyondSeek ? seekBackColor : seekAheadColor;

	float4 waveTop = getWaveTopColor();
	float4 waveBottom = waveHighlightColor;

	float4 color = (cursorBar < pixelBar ? waveUnplayedColor : lerp(waveBottom, waveTop, tc.y));

	if (pixelBar == cursorBar)
	{
		if (seeking)
		{
			if (isBeyondSeek)
			{
				color = lerp(color, seekColor, seekColor.a);
				color = lerp(color, waveUnplayedColor, barCoverage);
			}
			else
			{
				color = lerp(color, lerp(waveUnplayedColor, seekColor, seekColor.a), barCoverage);
			}
		}
		else
		{
			color = lerp(color, waveUnplayedColor, barCoverage);
		}
	}
	else if (seeking)
	{
		bool afterCursor = tc.x + pixelSize.x > cursorPos;
		float4 seekColor = isBeyondSeek ? seekBackColor : seekAheadColor;

		if ((afterCursor + isBeyondSeek) == 1)
		{
			color = lerp(color, seekColor, seekColor.a);
		}
	}

	if (isGap)
	{
		color = lerp(color, bgColor, tc.y * 0.35 + 0.5);
	}

	return color;
}

float4 getReflectionColor(float2 tc, float2 pixelSize, int pixelBar, int cursorBar, float barCoverage, float4 bgColor, bool isGap)
{
	float4 color;

	float4 reflectionUnplayedColor = multiply(waveUnplayedColor, 0.8980);
	float4 reflectionHighlightColor = getReflectionHightlightColor();

	if (isGap)
	{
		color = bgColor;
	}
	else if (pixelBar == cursorBar)
	{
		color = lerp(reflectionHighlightColor, reflectionUnplayedColor, barCoverage);
	}
	else
	{
		color = cursorPos < tc.x + pixelSize.x ? reflectionUnplayedColor : reflectionHighlightColor;
	}

	return color;
}

float4 evaluate(float2 tc)
{
	float mainAxisLength = (horizontal ? viewportSize.x : viewportSize.y);
	float2 pixelSize = getPixelSize();

	bool isGap = false;
	float rmsData = rmsSampling(tc, pixelSize, isGap);

	tc.y += 0.5;

	// Reflection
	if (tc.y < 0)
	{
		// Invert upper half-waves to imitate reflection
		rmsData = 1 - rmsData;

		// Squeeze reflection
		tc.y *= 3.5;
	}

	rmsData -= 0.5;
	rmsData *= 2.5;

	bool above = abs(tc.y) > abs(rmsData);
	float4 bgColor = panelBackgroundColor * ((0.93 - (tc.x * 0.08)) + ((tc.y * 0.1) - 0.07));

	if (above || abs(tc.y) < 1.33 * pixelSize.y)
	{
		return bgColor;
	}

	int pixelBar = ceil(mainAxisLength * (tc.x + pixelSize.x) / 3.0);
	int cursorBar = ceil(mainAxisLength * cursorPos / 3.0);
	float barCoverage = (cursorBar * 3.0 - (mainAxisLength * cursorPos)) / 3.0;

	float4 color = tc.y > 0
		? getWaveColor(tc, pixelSize, pixelBar, cursorBar, barCoverage, bgColor, isGap)
		: getReflectionColor(tc, pixelSize, pixelBar, cursorBar, barCoverage, bgColor, isGap);

	return color;
}

PS_IN VS(VS_IN input)
{
    float pixelWidth = horizontal
        ? 1 / viewportSize.x
        : 1 / viewportSize.y;

    PS_IN output = (PS_IN)0;
    
    // Move left to fill 1st empty pixel
    output.pos = float4(input.pos - float2(pixelWidth, 0), 0, 1);

    if (horizontal)
    {
    	float firstBarAlignment = (flipped ? 2*pixelWidth : -2*pixelWidth);
        output.tc = float4((input.tc.xy + float2(1.0 + firstBarAlignment, 0)) * float2(0.5, 1.0), 0, 1);
    }
    else
    {
    	float firstBarAlignment = (flipped ? 3*pixelWidth : -1*pixelWidth);
        output.tc = float4((-input.pos.yx + float2(1.0 + firstBarAlignment, 0)) * float2(0.5, 1.0), 0, 1);
    }

    if (flipped)
    {
        output.tc.x = 1.0 - output.tc.x;
    }

	return output;
}

float4 PS(PS_IN input) : SV_Target
{
	float4 color = evaluate(input.tc);

	return color;
}

technique Render9
{
	pass
	{
		VertexShader = compile vs_2_0 VS();
		PixelShader = compile ps_3_0 PS();
	}
}

technique10 Render10
{
	pass P0
	{
		SetGeometryShader(0);
		SetVertexShader(CompileShader(vs_4_0, VS()));
		SetPixelShader(CompileShader(ps_4_0, PS()));
	}
}
