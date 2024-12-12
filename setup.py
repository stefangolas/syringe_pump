from setuptools import setup, find_packages

setup(
    name="syringe_pump",
    version="0.1.0",
    packages=find_packages(),
    install_requires=[
        "requests>=2.25.0",
        "agrow-pumps>=0.1.0",
        "flask>=2.0.0",
    ],
    entry_points={
        'console_scripts': [
            'syringe-pump-server=syringe_pump.motor_server:main',
        ],
    },
    author="Stefan Golas",
    description="A Python library for controlling syringe pumps",
    long_description=open("README.md").read(),
    long_description_content_type="text/markdown",
    url="https://github.com/yourusername/syringe_pump",
    classifiers=[
        "Programming Language :: Python :: 3",
        "License :: OSI Approved :: MIT License",
        "Operating System :: OS Independent",
    ],
    python_requires=">=3.6",
)
