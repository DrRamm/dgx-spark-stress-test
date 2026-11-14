import unittest
from supervise import policy, GIB, sensor_readings
from pathlib import Path
import tempfile
class Guards(unittest.TestCase):
    def test_healthy(self):
        self.assertIsNone(policy(60, 20*GIB, {'acpitz:temp1_input': 65, 'nvme:temp1_input': 45}))
    def test_temperature_limits(self):
        self.assertIsNotNone(policy(80, 20*GIB, {}))
        self.assertIsNotNone(policy(50, 20*GIB, {'nvme:temp1_input': 70}))
        self.assertIsNotNone(policy(50, 20*GIB, {'acpitz:temp1_input': 85}))
    def test_memory_and_sensor_failure(self):
        self.assertIsNotNone(policy(50, 7*GIB, {}))
        self.assertIsNotNone(policy(float('nan'), 20*GIB, {}))
class SensorDiscovery(unittest.TestCase):
    def test_suffixed_acpi_names_and_missing_sensor(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for index, name in enumerate(['acpitz_0', 'acpitz_1', 'nvme']):
                folder = root / f'hwmon{index}'
                folder.mkdir()
                (folder / 'name').write_text(name)
                (folder / 'temp1_input').write_text('45000')
            self.assertEqual(len(sensor_readings(root)), 3)
            (root / 'hwmon2' / 'temp1_input').unlink()
            with self.assertRaises(RuntimeError): sensor_readings(root)
    def test_invalid_temperature(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'hwmon0'
            folder.mkdir()
            (folder / 'name').write_text('acpitz_0')
            (folder / 'temp1_input').write_text('nan')
            with self.assertRaises(RuntimeError): sensor_readings(root)
if __name__ == '__main__': unittest.main()
