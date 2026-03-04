from setuptools import setup, find_packages

setup(
    name='cable',
    version='0.10.1',  # Update to match your PKGBUILD version
    py_modules=['Cable'],
    packages=['cable_core', 'cable_core.layout_strategies', 'cables', 'cables.config', 'cables.ui', 'cables.utils', 'cables.features', 'graph'],
    package_data={
        'cable_core': ['*.py'],
        'cable_core.layout_strategies': ['*.py'],
        'cables': ['*.py', '*.md'],
        'cables.config': ['*.py'],
        'cables.ui': ['*.py'],
        'cables.utils': ['*.py'],
        'cables.features': ['*.py'],
    },
    include_package_data=True,
    entry_points={
        'console_scripts': [
            'cable = Cable:main',
        ],
    },
)
