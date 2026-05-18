import serial
import time
import numpy as np
from PIL import Image

# ==========================================
# CONFIGURATION
# ==========================================
COM_PORT = 'COM8'  # Set to COM8 as per your latest run
BAUD_RATE = 115200
IMAGE_PATH = r"C:/College/Sem 6/EL/ascent_final_2/imresizer-image_2026-05-15_133529009.png"

# MNIST Training Constants
MNIST_MEAN = 0.1307
MNIST_STD = 0.3081
INPUT_SCALE = 2.8215 / 127.0  # Common INT8 scale factor

def preprocess_image(image_path):
    # 1. Grayscale and resize to exactly 28x28 (784 pixels)
    img = Image.open(image_path).convert('L').resize((28, 28))
    pixels = np.array(img, dtype=np.float32)

    # 2. Inversion Check
    if pixels.mean() > 128:
        print("=> Auto-inverting image (Black-on-White detected)...")
        pixels = 255.0 - pixels
    else:
        print("=> Image is already White-on-Black...")

    # 3. THE FIX: KILL GRAY NOISE
    pixels = np.where(pixels < 80, 0.0, 255.0)

    # -- DEBUG: Show ASCII Art of what the FPGA will see --
    print("\n--- What the FPGA Sees ---")
    for row in pixels:
        print("".join(['#' if p > 80 else '.' for p in row]))
    print("--------------------------\n")

    # 4. Normalization
    pixels = pixels / 255.0
    pixels = (pixels - MNIST_MEAN) / MNIST_STD

    # 5. Quantization to Signed INT8 [-128 to 127]
    pixels_quantized = np.round(pixels / INPUT_SCALE)
    pixels_int8 = np.clip(pixels_quantized, -128, 127).astype(np.int8)

    # 6. Pack as Unsigned Bytes for UART (2's complement)
    pixel_bytes = pixels_int8.flatten().view(np.uint8).tobytes()
    
    return pixel_bytes, pixels_int8

def send_image():
    try:
        print("Processing image...")
        pixel_bytes, debug_int8 = preprocess_image(IMAGE_PATH)
        
        print(f"INT8 Stats - Min val: {debug_int8.min()}, Max val: {debug_int8.max()}")
        print(f"Payload size: {len(pixel_bytes)} bytes")

        # Open Serial Port
        print(f"\nOpening {COM_PORT}...")
        ser = serial.Serial(COM_PORT, BAUD_RATE, timeout=2)
        time.sleep(0.5)  # Allow Windows/OS to stabilize the serial line
        
        # ==========================================
        # THE DEADLOCK PREVENTER
        # ==========================================
        input("\n[STOP] Press the physical RESET button (BTN0) on your PYNQ-Z2 board NOW, then press ENTER to send data...")

        # Flush any stale data from previous runs hanging in the buffer
        ser.reset_input_buffer()
        ser.reset_output_buffer()

        # Send Data
        print("\nSending 784 bytes to FPGA...")
        ser.write(pixel_bytes)

        # Wait for Response
        print("Waiting for FPGA inference...")
        response = ser.read(1)
        
        if response:
            raw_byte = int.from_bytes(response, byteorder='big')
            
            # Mask out the upper 4 bits. ASCENT sends {4'b0000, pred_class}
            predicted_class = raw_byte & 0x0F
            
            print(f"\n>>> Raw byte received : 0x{raw_byte:02X} ({raw_byte})")
            print(f">>> Predicted class   : {predicted_class}")
        else:
            print("\n[!] No response from FPGA. Check your UART pins and Reset.")

        ser.close()
    except Exception as e:
        print(f"Error: {e}")

if __name__ == "__main__":
    send_image()
