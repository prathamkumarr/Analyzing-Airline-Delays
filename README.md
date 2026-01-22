# Analyzing Airline Delays 

This project focuses on analyzing flight delay patterns across various airlines using real-world aviation data.  
The goal is to identify trends, major causes of delays, and airline performance using Python and SQL.

The workflow follows a **complete data analysis pipeline**:
Data Cleaning -> EDA -> SQL Analysis -> Insights

---

## Problem Statement

Airline delays cause financial loss, customer dissatisfaction, and operational inefficiencies.  
This project answers questions like:

- Which airlines have the highest delays?
- What are the most common causes of delays?
- Are delays seasonal or airline-specific?
- How do different airlines compare in terms of on-time performance?

---

## Dataset

- Flight delay dataset (public aviation data)
- Contains information about:
  - Airline
  - Delay duration
  - Delay reasons
  - Flight timings
  - Airport details

---

## Tech Stack

- **Python** (Pandas, NumPy, Matplotlib, Seaborn)
- **Jupyter Notebook** (Data cleaning & EDA)
- **PostgreSQL** (Structured analysis)
- **SQL** (Aggregation & insights)
- **Git & GitHub** (Version control)

---

## Project Workflow

### Data Cleaning (Python)
- Removed missing & invalid records
- Fixed data types
- Standardized column names
- Handled outliers

### Exploratory Data Analysis (EDA)
- Airline-wise delay distribution
- Delay reason analysis
- Time-based trends
- Visual comparisons

### SQL Analysis (PostgreSQL)
- Imported cleaned dataset into PostgreSQL
- Performed aggregations using SQL
- Identified worst & best performing airlines
- Calculated average delay metrics

---

## Key Insights

- Certain airlines consistently show higher delay averages
- Weather & carrier-related issues are top delay causes
- Peak travel seasons experience higher delays
- Delay patterns vary significantly by airline and route

---
## Dataset Source 
- Kaggle (https://www.kaggle.com/datasets/abdurrehmankhalid/delayedflights)

## Open Notebook in Google Colab

[![Open In Colab](https://colab.research.google.com/assets/colab-badge.svg)]
(https://colab.research.google.com/github/prathamkumarr/Analyzing-Airline-Delays/blob/main/Airlines_delay_dataset.ipynb)


