import unittest
from supervise import policy, GIB, sensor_readings
from pathlib import Path
import tempfile
class Guards(unittest.TestCase):
    def test_healthy(self):
        self.assertIsNone(policy(60, 20*GIB, {'acpitz:temp1_input': 65, 'nvme:temp1_input': 45}))
    def test_temperature_limits(self):
        self.assertIsNotNone(policy(99, 20*GIB, {}))
        self.assertIsNotNone(policy(50, 20*GIB, {'nvme:temp1_input': 82}))
        self.assertIsNotNone(policy(50, 20*GIB, {'acpitz:temp1_input': 99}))
    def test_nvme_composite_not_individual_sensor(self):
        self.assertIsNone(policy(78, 20*GIB, {'nvme:hwmon7:temp1_input':58.85, 'nvme:hwmon7:temp2_input':70.85}))
        self.assertIsNone(policy(78, 20*GIB, {'nvme:hwmon7:temp1_input':81.9, 'nvme:hwmon7:temp2_input':85}))
        self.assertIsNotNone(policy(78, 20*GIB, {'nvme:hwmon7:temp1_input':82}))
    def test_authorized_ninety_nine_degree_boundary(self):
        self.assertIsNone(policy(98.9, 20*GIB, {'acpitz_0:hwmon0:temp1_input':98.9}))
        self.assertIsNotNone(policy(99, 20*GIB, {}))
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
                if name == 'nvme':
                    (folder / 'temp1_label').write_text('Composite')
                    (folder / 'temp1_alarm').write_text('0')
                (folder / 'temp1_input').write_text('45000')
            self.assertEqual(len(sensor_readings(root)), 3)
            (root / 'hwmon2' / 'temp1_input').unlink()
            with self.assertRaises(RuntimeError): sensor_readings(root)
    def test_nvme_alarm_and_wrong_label_fail_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'hwmon0'
            folder.mkdir()
            (folder / 'name').write_text('nvme')
            (folder / 'temp1_label').write_text('Composite')
            (folder / 'temp1_alarm').write_text('1')
            with self.assertRaisesRegex(RuntimeError, 'hardware temperature alarm'): sensor_readings(root)
            (folder / 'temp1_alarm').write_text('0')
            (folder / 'temp1_label').write_text('Sensor 1')
            with self.assertRaisesRegex(RuntimeError, 'mapping changed'): sensor_readings(root)
    def test_invalid_temperature(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / 'hwmon0'
            folder.mkdir()
            (folder / 'name').write_text('acpitz_0')
            (folder / 'temp1_input').write_text('nan')
            with self.assertRaises(RuntimeError): sensor_readings(root)
if __name__ == '__main__': unittest.main()
