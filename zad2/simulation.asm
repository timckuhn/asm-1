global start
global step
global clean

; zależności z libc
extern malloc
extern calloc
extern free
extern memcpy

; tylko do debugu
; najlepiej potem usunąć
extern debug_matrix

; stałe
SIZE_OF_FLOAT equ 4
SIZE_OF_QWORD equ 8
SIZE_OF_DQWORD equ 16
FLOATS_IN_DQWORD equ 4

; makra do utrzymywania wyrównania stosu
; koszty wydajnościowe, za to wygoda w programowaniu
; trochę mało w stylu niskopoziomowym...
; poza tym zakładam, że pushujemy qwordy zawsze
%macro align_call 1
  sub rsp, SIZE_OF_QWORD
  call %1
  add rsp, SIZE_OF_QWORD
%endmacro

%macro align_push 1
  sub rsp, SIZE_OF_QWORD
  push %1
%endmacro

%macro align_pop 1
  pop %1
  add rsp, SIZE_OF_QWORD
%endmacro

%macro matrix_debug 3
  mov rdi, qword[%1]
  mov esi, %2
  mov edx, %3
  align_call debug_matrix
%endmacro

%macro big_matrix_debug 1
  mov esi, dword[n]
  add esi, 2
  mov edx, dword[m]
  add edx, 2
  matrix_debug %1, esi, edx
%endmacro

section .data
  n dd 0 ; wysokość
  m dd 0 ; szerokość
  M dq 0 ; wskaźnik do danych
  G dq 0 ; wskaźnik do grzejników
  C dq 0 ; wskaźnik do chłodnic
  ratio dd 0.0 ; współczynnik (float), waga
  size dd 0 ; wielkość macierzy, na których będę robić SSE
  result_matrix dq 0 ; wskaźnik do macierzy, w której będzie wynik
  delta_matrix dq 0 ; wskaźnik do macierzy, która będzie = ratio * oryginalna
  pi dd 3.1415 ; wartość ~PI, sztuczna wartość dla komórek

section .text
start:
  align_call assign_arguments
  align_call calculate_size
  align_call alloc_matrices
  ret

assign_arguments:
  ; przypisujemy argumenty
  mov dword[n], edi
  mov dword[m], esi
  mov qword[M], rdx
  mov qword[G], rcx
  mov qword[C], r8
  movss dword[ratio], xmm0
  ret

calculate_size:
  ; liczymy size = (n + 2) * (m + 2)
  mov eax, dword[n]
  add eax, 2
  mov r9d, dword[m]
  add r9d, 2
  imul eax, r9d
  mov dword[size], eax
  ret


alloc_matrices:
  ; edi = size * sizeof(float)
  mov edi, dword[size]
  imul edi, SIZE_OF_FLOAT
  ; rax = malloc(edi)
  align_call malloc
  ; result_matrix = malloc(size * sizeof(float));
  mov qword[result_matrix], rax
  ; edi = size * sizeof(float)
  mov edi, dword[size]
  mov esi, SIZE_OF_FLOAT
  ; rax = malloc(edi)
  align_call calloc
  ; delta_matrix = malloc(size * sizeof(float));
  mov qword[delta_matrix], rax
  ret

clean:
clean_matrices:
  ; free(result_matrix)
  mov rdi, qword[result_matrix]
  align_call free
  ; free(delta_matrix)
  mov rdi, qword[delta_matrix]
  align_call free
  ret

; inicjalizuję wartość dla rogów result_matrix
; zasadniczo niepotrzebne, ale ładnie wygląda na debugu
init_result_corners:
  mov rdi, qword[result_matrix]
  mov esi, dword[pi]
  ; lewy górny róg (result_matrix[0])
  mov dword[rdi], esi
  mov edx, dword[m]
  ; edx = m + 1
  inc edx
  imul edx, SIZE_OF_FLOAT
  add rdi, rdx
  ; prawy górny róg (result_matrix[m + 1])
  mov dword[rdi], esi
  mov ecx, dword[n]
  inc ecx
  mov r8d, dword[m]
  add r8d, 2
  ; ecx = (n + 1) * (m + 2)
  imul ecx, r8d
  imul ecx, SIZE_OF_FLOAT
  add rdi, rcx
  ; prawy dolny róg (result_matrix[m + 1 + (n + 1) * (m + 2)])
  mov dword[rdi], esi
  sub rdi, rdx
  ; lewy dolny róg (result_matrix[(n + 1) * (m + 2)])
  mov dword[rdi], esi
  ret

; kopiujemy grzejniki do result_matrix
init_result_G:
  ; w rdi result_matrix++
  mov rdi, qword[result_matrix]
  add rdi, SIZE_OF_FLOAT
  mov rsi, qword[G]
  mov edx, dword[m]
  imul edx, SIZE_OF_FLOAT
  ; memcpy(result_matrix + 1, G, sizeof(float) * m)
  align_call memcpy
  ; mamy skopiowane górne grzejniki, teraz dolne
  mov rdi, qword[result_matrix]
  mov ecx, dword[n]
  inc ecx
  mov r8d, dword[m]
  add r8d, 2
  imul ecx, r8d
  inc ecx
  ; ecx = (n + 1) * (m + 2) + 1
  imul ecx, SIZE_OF_FLOAT
  ; arytmetyka wskaźników
  add rdi, rcx
  mov rsi, qword[G]
  mov edx, dword[m]
  imul edx, SIZE_OF_FLOAT
  ; memcpy(result_matrix + (n + 1) * (m + 2) + 1, G, sizeof(float) * m)
  align_call memcpy
  ret

init_result_C:
  ; w r8 będziemy trzymać wskaźnik na lewe pole chłodnic w result_matrix
  ; w r9 -||- prawe pole chłodnic
  ; w r10 trzymamy C + i (* SIZE_OF_FLOAT), dla i = 0 .. n - 1
  mov r8, qword[result_matrix]
  mov edi, dword[m]
  add edi, 2
  imul edi, SIZE_OF_FLOAT
  ; w rdi trzymamy (m + 2) * SIZE_OF_FLOAT
  add r8, rdi
  ; r8 = result_matrix + m + 2
  mov r9, r8
  add r9, rdi
  sub r9, SIZE_OF_FLOAT
  ; r9 = (result_matrix + m + 2) + (m + 1)
  ; będziemy zmieniać n wierszy
  mov ecx, dword[n]
  ; r10 = C
  mov r10, qword[C]
init_result_C_loop:
  mov r11d, dword[r10]
  ; *r8 = C[i]; *r9 = C[i];
  mov dword[r8], r11d
  mov dword[r9], r11d
  ; r8 += m + 2; r9 += m + 2; r10++;
  add r8, rdi
  add r9, rdi
  add r10, SIZE_OF_FLOAT
  loop init_result_C_loop
  ret

init_result_M:
  ; będziemy zmieniać n wierszy
  mov ecx, dword[n]
init_result_M_loop:
  ; liczymy, który wiersz kopiujemy = i (1 .. n)
  mov r8d, dword[n]
  sub r8d, ecx
  inc r8d
  ; rdi = result_matrix
  mov rdi, qword[result_matrix]
  ; r9d = i
  mov r9d, r8d
  ; r10d = m + 2
  mov r10d, dword[m]
  add r10d, 2
  ; r9d = 1 + (m + 2) * i
  imul r9d, r10d
  inc r9d
  imul r9d, SIZE_OF_FLOAT
  ; rdi = result_matrix + 1 + (m + 2) * i (dest dla memcpy)
  add rdi, r9
  ; rsi = M
  mov rsi, qword[M]
  ; i--
  dec r8d
  mov r9d, dword[m]
  ; r8d = (i - 1) * m
  imul r8d, r9d
  imul r8d, SIZE_OF_FLOAT
  ; rsi = M + (i - 1) * m (src dla memcpy)
  add rsi, r8
  ; edx = m (size dla memcpy)
  mov edx, dword[m]
  imul edx, SIZE_OF_FLOAT
  ; zachowujemy counter pętli
  align_push rcx
  ; memcpy(dest = rdi, src = rsi, m)
  align_call memcpy
  ; przywracamy counter pętli
  align_pop rcx
  loop init_result_M_loop
  ret

init_result:
  align_call init_result_corners
  align_call init_result_G
  align_call init_result_C
  align_call init_result_M
  ret

; kod jak w init_result_M (tylko kopiujemy w drugą stronę),
; więc komentarze pominę.
move_result:
  mov ecx, dword[n]
move_result_loop:
  mov r8d, dword[n]
  sub r8d, ecx
  inc r8d
  mov rdi, qword[result_matrix]
  mov r9d, r8d
  mov r10d, dword[m]
  add r10d, 2
  imul r9d, r10d
  inc r9d
  imul r9d, SIZE_OF_FLOAT
  add rdi, r9
  mov rsi, qword[M]
  dec r8d
  mov r9d, dword[m]
  imul r8d, r9d
  imul r8d, SIZE_OF_FLOAT
  add rsi, r8
  mov edx, dword[m]
  imul edx, SIZE_OF_FLOAT
  ; kopiujemy w drugą stronę, więc zamieńmy argumenty
  xchg rdi, rsi
  align_push rcx
  align_call memcpy
  align_pop rcx
  loop move_result_loop
  ret

step:
  align_call init_result
  align_call calculate_delta
  align_call add_delta
  align_call move_result
  ret

; (rdi, rsi, rdx, rcx, r8, r9) (rax, r10, r11)
calculate_delta:
  ;
  mov rdi, qword[delta_matrix]
  mov rsi, qword[result_matrix]
  mov edx, dword[n]
  add edx, 2
  mov r8d, dword[m]
  add r8d, 2
  imul edx, r8d
  imul rdx, SIZE_OF_FLOAT
  align_call memcpy
  ;
  ret

; dodaje delta_matrix do result_matrix
; tj. result_matrix += delta_matrix
; założenia:
;   w ecx trzymamy counter pętli
;   w rdi trzymamy wskaźnik na result_matrix
;   w rsi trzymamy wskaźnik na delta_matrix
add_delta:
  big_matrix_debug result_matrix
  big_matrix_debug delta_matrix
  mov ecx, dword[size]
  mov r10d, ecx
  imul r10, SIZE_OF_FLOAT
  mov rdi, qword[result_matrix]
  add rdi, r10
  mov rsi, qword[delta_matrix]
  add rsi, r10
  ; rdi oraz rsi wskazują na komórkę za końcem i-tego wiersza
add_delta_loop:
  cmp ecx, FLOATS_IN_DQWORD
  jge add_delta_loop_4plus
  ; result_matrix--; delta_matrix--;
  sub rdi, SIZE_OF_FLOAT
  sub rsi, SIZE_OF_FLOAT
  fld dword[rdi]
  fld dword[rsi]
  faddp
  fstp dword[rdi]
  dec ecx
  jmp add_delta_loop_check
add_delta_loop_4plus:
  sub rdi, SIZE_OF_DQWORD
  sub rsi, SIZE_OF_DQWORD
  movdqu xmm0, oword[rdi]
  movdqu xmm1, oword[rsi]
  addps xmm0, xmm1
  movdqu oword[rdi], xmm0
  sub ecx, FLOATS_IN_DQWORD
add_delta_loop_check:
  cmp ecx, 0
  jg add_delta_loop
  big_matrix_debug result_matrix
  ret
